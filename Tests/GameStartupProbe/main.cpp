// Integration test for the game's own Steamworks.NET binding. The test process
// embeds that Unity installation's Mono runtime using its public embedding API.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <json/json.h>

namespace fs = std::filesystem;

template<typename T> T require(T value, const char* what) {
    if (!value) throw std::runtime_error(std::string("Unavailable: ") + what);
    return value;
}

template<typename Function> Function symbol(HMODULE module, const char* name) {
    return reinterpret_cast<Function>(require(GetProcAddress(module, name), name));
}

HMODULE load(const fs::path& path) {
    const auto module = LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!module) throw std::runtime_error("Cannot load " + path.u8string() + " (Windows error " +
                                          std::to_string(GetLastError()) + ")");
    return module;
}

struct MonoDomain; struct MonoAssembly; struct MonoImage; struct MonoClass;
struct MonoMethod; struct MonoObject; struct MonoString; struct MonoField;
struct MonoVTable; struct MonoType; struct MonoMethodSignature;

struct Mono {
    HMODULE module;
    // Signatures from mono/jit/jit.h and mono/metadata/{assembly,class,object}.h.
    // Bind only the functions used by this test, from the game-supplied DLL.
#define MONO(result, name, ...) result (*name)(__VA_ARGS__) = symbol<decltype(name)>(module, #name)
    MONO(void, mono_set_assemblies_path, const char*);
    MONO(void, mono_set_config_dir, const char*);
    MONO(MonoDomain*, mono_jit_init_version, const char*, const char*);
    MONO(void, mono_jit_cleanup, MonoDomain*);
    MONO(MonoAssembly*, mono_domain_assembly_open, MonoDomain*, const char*);
    MONO(MonoImage*, mono_assembly_get_image, MonoAssembly*);
    MONO(void, mono_dllmap_insert, MonoImage*, const char*, const char*, const char*, const char*);
    MONO(MonoClass*, mono_class_from_name, MonoImage*, const char*, const char*);
    MONO(MonoMethod*, mono_class_get_method_from_name, MonoClass*, const char*, int);
    MONO(MonoMethodSignature*, mono_method_signature, MonoMethod*);
    MONO(int, mono_signature_is_instance, MonoMethodSignature*);
    MONO(MonoType*, mono_signature_get_params, MonoMethodSignature*, void**);
    MONO(int, mono_type_is_byref, MonoType*);
    MONO(MonoClass*, mono_class_from_mono_type, MonoType*);
    MONO(MonoClass*, mono_get_string_class, void);
    MONO(MonoClass*, mono_get_intptr_class, void);
    MONO(MonoObject*, mono_runtime_invoke, MonoMethod*, void*, void**, MonoObject**);
    MONO(MonoString*, mono_object_to_string, MonoObject*, MonoObject**);
    MONO(char*, mono_string_to_utf8, MonoString*);
    MONO(void, mono_free, void*);
    MONO(MonoVTable*, mono_class_vtable, MonoDomain*, MonoClass*);
    MONO(void, mono_runtime_class_init, MonoVTable*);
    MONO(MonoField*, mono_class_get_fields, MonoClass*, void**);
    MONO(uint32_t, mono_field_get_flags, MonoField*);
    MONO(MonoType*, mono_field_get_type, MonoField*);
    MONO(const char*, mono_field_get_name, MonoField*);
    MONO(void, mono_field_static_get_value, MonoVTable*, MonoField*, void*);
#undef MONO

    std::string text(MonoString* value) const {
        if (!value) return {};
        std::unique_ptr<char, decltype(mono_free)> bytes(require(mono_string_to_utf8(value), "UTF-8 string"), mono_free);
        return bytes.get();
    }

    std::string describe(MonoObject* value) const {
        MonoObject* exception = nullptr;
        auto string = mono_object_to_string(value, &exception);
        if (exception || !string) throw std::runtime_error("Managed value could not be formatted");
        return text(string);
    }
};

bool probe(const fs::path& data, Json::Value& report) {
    auto managed = data / "Managed";
    auto runtime = data.parent_path() / "MonoBleedingEdge";
    auto library = data / "Plugins/x86_64/steam_api64.dll";
    auto wrapper = managed / "com.rlabrecque.steamworks.net.dll";
    for (const auto& file : {managed / "mscorlib.dll", library, wrapper}) {
        if (!fs::is_regular_file(file)) throw std::runtime_error("Missing " + file.u8string());
    }
    require(SetEnvironmentVariableW(L"SteamAppId", L"4348910"), "SteamAppId");
    require(SetEnvironmentVariableW(L"SteamGameId", L"4348910"), "SteamGameId");
    Mono mono{load(runtime / "EmbedRuntime/mono-2.0-bdwgc.dll")};
    mono.mono_set_assemblies_path(managed.u8string().c_str());
    mono.mono_set_config_dir((runtime / "etc").u8string().c_str());
    std::unique_ptr<MonoDomain, decltype(mono.mono_jit_cleanup)> domain(
        require(mono.mono_jit_init_version("GameStartupProbe", "v4.0.30319"), "Unity Mono domain"),
        mono.mono_jit_cleanup);
    auto assembly = require(mono.mono_domain_assembly_open(domain.get(), wrapper.u8string().c_str()), "Steamworks.NET assembly");
    auto image = require(mono.mono_assembly_get_image(assembly), "Steamworks.NET image");
    auto shutdown = symbol<void(*)()>(load(library), "SteamAPI_Shutdown");
    mono.mono_dllmap_insert(image, "steam_api64", nullptr, library.u8string().c_str(), nullptr);
    auto api = require(mono.mono_class_from_name(image, "Steamworks", "SteamAPI"), "Steamworks.SteamAPI");
    auto init = require(mono.mono_class_get_method_from_name(api, "InitEx", 1), "SteamAPI.InitEx");
    auto signature = require(mono.mono_method_signature(init), "InitEx signature");
    void* parameters = nullptr;
    auto param = mono.mono_signature_get_params(signature, &parameters);
    if (mono.mono_signature_is_instance(signature) || !param || !mono.mono_type_is_byref(param) ||
        mono.mono_class_from_mono_type(param) != mono.mono_get_string_class())
        throw std::runtime_error("Expected static SteamAPI.InitEx(out string)");
    struct CloseSteam {
        void (*shutdown)();
        ~CloseSteam() { shutdown(); }
    } closeSteam{shutdown};

    MonoString* error = nullptr;
    void* arguments[] = {&error};
    MonoObject* exception = nullptr;
    auto result = mono.mono_runtime_invoke(init, nullptr, arguments, &exception);
    if (exception) throw std::runtime_error(mono.describe(exception));
    const auto status = mono.describe(require(result, "InitEx result"));
    report["result"] = status;
    report["error"] = error ? Json::Value(mono.text(error)) : Json::Value();

    auto context = require(mono.mono_class_from_name(image, "Steamworks", "CSteamAPIContext"), "CSteamAPIContext");
    auto table = require(mono.mono_class_vtable(domain.get(), context), "CSteamAPIContext static fields");
    mono.mono_runtime_class_init(table);
    void* iterator = nullptr;
    while (auto field = mono.mono_class_get_fields(context, &iterator)) {
        const auto flags = mono.mono_field_get_flags(field);
        constexpr unsigned isStatic = 0x10, accessMask = 0x7, isPublic = 0x6;
        if (!(flags & isStatic) || (flags & accessMask) == isPublic) continue;
        void* pointer = nullptr;
        if (mono.mono_class_from_mono_type(mono.mono_field_get_type(field)) == mono.mono_get_intptr_class())
            mono.mono_field_static_get_value(table, field, &pointer);
        report[mono.mono_field_get_name(field)] = pointer != nullptr;
    }
    return status == "k_ESteamAPIInitResult_OK";
}

int wmain(int argc, wchar_t** argv) {
    if (argc != 3) return 2;
    Json::Value report;
    report["started"] = true;
    report["writes"] = false;
    bool ok = false;
    try { ok = probe(fs::absolute(argv[1]), report); }
    catch (const std::exception& e) { report["exception"] = e.what(); }
    const fs::path output(argv[2]);
    fs::path partial = output;
    partial += L".tmp";
    std::ofstream stream(partial, std::ios::binary);
    stream << report;
    stream.close();
    if (!stream || !MoveFileExW(partial.c_str(), output.c_str(), MOVEFILE_REPLACE_EXISTING)) {
        DeleteFileW(partial.c_str());
        return 1;
    }
    return ok ? 0 : 1;
}
