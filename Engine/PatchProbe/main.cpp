// Read-only inventory within the Wine server selected by the caller.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <tlhelp32.h>
#include <json/json.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using std::runtime_error;
struct HandleCloser {
    void operator()(HANDLE handle) const { if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle); }
};
using Handle = std::unique_ptr<void, HandleCloser>;
using Identity = std::array<DWORD, 3>;

Identity fileIdentity(const std::wstring& path) {
    Handle file(CreateFileW(path.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, 0, nullptr));
    if (file.get() == INVALID_HANDLE_VALUE)
        throw runtime_error("Cannot identify a module file: " + std::to_string(GetLastError()));
    BY_HANDLE_FILE_INFORMATION info{};
    if (!GetFileInformationByHandle(file.get(), &info)) throw runtime_error("File identity unavailable");
    if (!(info.nFileIndexHigh || info.nFileIndexLow)) throw runtime_error("File identity is not reliable");
    return {info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow};
}

Identity processIdentity(HANDLE process) {
    std::wstring path(32768, L'\0');
    DWORD size = static_cast<DWORD>(path.size());
    if (!QueryFullProcessImageNameW(process, 0, path.data(), &size)) throw runtime_error("Process image unavailable");
    path.resize(size);
    return fileIdentity(path);
}

std::wstring baseName(const std::wstring& path) {
    return path.substr(path.find_last_of(L"/\\") + 1);
}

bool sameName(const std::wstring& a, const std::wstring& b) {
    return CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_EQUAL;
}

bool absolutePath(const std::wstring& path) {
    auto separator = [](wchar_t c) { return c == L'/' || c == L'\\'; };
    if (path.size() < 2) return false;
    if (separator(path[0]) && separator(path[1])) return true;
    bool drive = (path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z');
    return drive && path.size() >= 3 && path[1] == L':' && separator(path[2]);
}

std::wstring pathValue(const Json::Value& value) {
    if (!value.isString()) throw runtime_error("Invalid inventory scope");
    std::string text = value.asString();
    if (text.empty() || text.find('\0') != std::string::npos) throw runtime_error("Invalid inventory scope");
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (!n) throw runtime_error("Invalid inventory scope");
    std::wstring path(n, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), path.data(), n);
    if (!absolutePath(path)) throw runtime_error("Invalid inventory scope");
    return path;
}

bool hexDigit(char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

// Accept the N, D, B, P and X forms used by Guid.TryParse. Echo the original nonce.
bool validNonce(std::string text) {
    const char* whitespace = " \t\r\n\f\v";
    auto first = text.find_first_not_of(whitespace);
    if (first == std::string::npos) return false;
    text = text.substr(first, text.find_last_not_of(whitespace) - first + 1);
    if (text.front() == '{' && text.find(',') != std::string::npos) {
        text.erase(std::remove_if(text.begin(), text.end(),
            [whitespace](char c) { return c && std::strchr(whitespace, c); }), text.end());
        size_t pos = 0;
        auto take = [&](char c) { if (pos == text.size() || text[pos] != c) return false; ++pos; return true; };
        for (int field = 0; field != 11; ++field) {
            if (!take(field ? ',' : '{') || (field == 3 && !take('{')) || !take('0') || !(take('x') || take('X'))) return false;
            size_t start = pos;
            while (pos < text.size() && text[pos] == '0') ++pos;
            size_t significant = pos;
            while (pos < text.size() && hexDigit(text[pos])) ++pos;
            size_t maxDigits = field == 0 ? 8 : (field < 3 ? 4 : 2);
            if (pos == start || pos - significant > maxDigits) return false;
        }
        return take('}') && take('}') && pos == text.size();
    }
    if (text.front() == '{' || text.front() == '(') {
        if (text.size() != 38 || text.back() != (text.front() == '{' ? '}' : ')')) return false;
        text = text.substr(1, 36);
    }
    if (text.size() != 32 && text.size() != 36) return false;
    for (size_t i = 0; i < text.size(); ++i) {
        bool dash = text.size() == 36 && (i == 8 || i == 13 || i == 18 || i == 23);
        if (dash ? text[i] != '-' : !hexDigit(text[i])) return false;
    }
    return true;
}

void checkEnd(const char* message) {
    if (GetLastError() != ERROR_NO_MORE_FILES) throw runtime_error(message);
}

Json::Value loadedModules(DWORD pid, const std::vector<std::wstring>& names, const std::vector<Identity>& expected) {
    Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid));
    if (snapshot.get() == INVALID_HANDLE_VALUE)
        throw runtime_error("Module inventory unavailable: " + std::to_string(GetLastError()));
    MODULEENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    if (!Module32FirstW(snapshot.get(), &entry)) throw runtime_error("Empty or inaccessible module inventory");
    std::set<Identity> found;
    size_t count = 0;
    do {
        if (++count > 4096 || wcslen(entry.szExePath) >= 259) throw runtime_error("Module inventory exceeds limits");
        auto name = baseName(entry.szExePath);
        if (std::any_of(names.begin(), names.end(), [&](const auto& n) { return sameName(n, name); }))
            found.insert(fileIdentity(entry.szExePath));
    } while (Module32NextW(snapshot.get(), &entry));
    checkEnd("Incomplete module inventory");
    Json::Value loaded(Json::arrayValue);
    for (const auto& identity : expected) loaded.append(found.count(identity) != 0);
    return loaded;
}

uint64_t ticks(FILETIME time) { return (uint64_t(time.dwHighDateTime) << 32) | time.dwLowDateTime; }

Json::Value inventory(const Json::Value& request) {
    if (!request.isObject() || !request["nonce"].isString() || !validNonce(request["nonce"].asString()) ||
        !request["modules"].isArray() || request["modules"].size() > 512) throw runtime_error("Invalid inventory scope");
    const auto game = pathValue(request["executable"]);
    std::vector<std::wstring> names;
    std::vector<Identity> expected;
    for (const auto& item : request["modules"]) names.push_back(pathValue(item));
    const auto gameID = fileIdentity(game);
    const auto gameName = baseName(game);
    for (auto& path : names) { expected.push_back(fileIdentity(path)); path = baseName(path); }

    Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
    if (snapshot.get() == INVALID_HANDLE_VALUE) throw runtime_error("Process inventory unavailable");
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    Json::Value matches(Json::arrayValue);
    unsigned unreadable = 0;
    for (BOOL more = Process32FirstW(snapshot.get(), &entry); more; more = Process32NextW(snapshot.get(), &entry)) {
        Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID));
        if (!process) { ++unreadable; continue; }
        try { if (processIdentity(process.get()) != gameID) continue; }
        catch (const runtime_error&) {
            if (sameName(entry.szExeFile, gameName)) throw runtime_error("Cannot identify a matching game process");
            ++unreadable;
            continue;
        }
        FILETIME created{}, exited{}, kernel{}, user{}, after{};
        if (!GetProcessTimes(process.get(), &created, &exited, &kernel, &user)) throw runtime_error("Cannot bind process creation time");
        Json::Value match;
        match["pid"] = static_cast<Json::UInt>(entry.th32ProcessID);
        match["created"] = std::to_string(ticks(created));
        match["loaded"] = loadedModules(entry.th32ProcessID, names, expected);
        if (processIdentity(process.get()) != gameID || !GetProcessTimes(process.get(), &after, &exited, &kernel, &user) ||
            ticks(after) != ticks(created) || ticks(exited) != 0) throw runtime_error("Game exited or changed during inventory");
        matches.append(match);
    }
    checkEnd("Incomplete process inventory");
    Json::Value result;
    result["ok"] = result["complete"] = true;
    result["nonce"] = request["nonce"];
    result["processes"] = matches;
    result["unreadable"] = unreadable;
    return result;
}

Json::Value readRequest(const wchar_t* path) {
    std::unique_ptr<FILE, decltype(&fclose)> file(_wfopen(path, L"rb"), fclose);
    if (!file) throw runtime_error("Cannot open request");
    constexpr size_t limit = 1024 * 1024;
    std::string bytes(limit + 1, '\0');
    size_t length = fread(bytes.data(), 1, bytes.size(), file.get());
    if (length > limit) throw runtime_error("Request exceeds size limit");
    if (ferror(file.get())) throw runtime_error("Cannot read request");
    // The bundled JsonCpp version accepts raw control characters inside strings
    // and treats a NUL as end of input. Reject both before parsing the request.
    bool quoted = false, escaped = false;
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = bytes[i];
        if (c < 0x20 && (quoted || (c != '\t' && c != '\r' && c != '\n')))
            throw runtime_error("Invalid JSON request");
        if (escaped) escaped = false;
        else if (quoted && c == '\\') escaped = true;
        else if (c == '"') quoted = !quoted;
    }
    Json::CharReaderBuilder builder;
    Json::CharReaderBuilder::strictMode(&builder.settings_);
    builder["stackLimit"] = 65;
    builder["rejectDupKeys"] = false;  // JsonDocument uses the last value for duplicate keys.
    std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
    Json::Value request;
    std::string errors;
    if (!reader->parse(bytes.data(), bytes.data() + length, &request, &errors)) throw runtime_error("Invalid JSON request");
    return request;
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    static_assert(sizeof(void*) == 8, "Windows x64 helper required");
    if (argc != 3 || !absolutePath(argv[1]) || !absolutePath(argv[2])) return 2;
    Json::Value result;
    int code = 0;
    try { result = inventory(readRequest(argv[1])); }
    catch (const std::exception& error) {
        result["ok"] = result["complete"] = false;
        result["error"] = error.what();
        code = 1;
    }
    Json::StreamWriterBuilder writer;
    writer["indentation"] = "";
    std::string json = Json::writeString(writer, result);
    FILE* file = _wfopen(argv[2], L"wb");
    if (!file) return 1;
    const bool written = fwrite(json.data(), 1, json.size(), file) == json.size();
    return fclose(file) == 0 && written ? code : 1;
}
