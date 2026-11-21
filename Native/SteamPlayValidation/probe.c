/* Standalone runtime acceptance probes. No Steam SDK or commercial runtime code.
 * Build with MinGW: gcc probe.c -o probe.exe -ld3d11 -ld3d12 -ldxgi -lole32 -luuid
 * Steam mode only initializes and reads metadata; it never writes achievements/saves.
 */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr) do { HRESULT hr_ = (expr); if (FAILED(hr_)) { \
    printf("FAIL %s hr=%#lx\n", #expr, (unsigned long)hr_); return 1; } } while (0)

static int d3d11_probe(void) {
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL level;
    CHECK(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                           D3D11_SDK_VERSION, &device, &level, &context));
    D3D11_TEXTURE2D_DESC desc = {0};
    desc.Width = desc.Height = 4; desc.MipLevels = desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT; desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D *target = NULL, *staging = NULL;
    ID3D11RenderTargetView *view = NULL;
    CHECK(ID3D11Device_CreateTexture2D(device, &desc, NULL, &target));
    CHECK(ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)target, NULL, &view));
    const FLOAT color[] = {1.f, 0.f, 0.f, 1.f};
    ID3D11DeviceContext_ClearRenderTargetView(context, view, color);
    desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    CHECK(ID3D11Device_CreateTexture2D(device, &desc, NULL, &staging));
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging, (ID3D11Resource *)target);
    D3D11_MAPPED_SUBRESOURCE mapped;
    CHECK(ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped));
    unsigned char *pixel = mapped.pData;
    int correct = pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 255;
    printf("D3D11 feature_level=%#x GPU readback RGBA=%u,%u,%u,%u %s\n",
           level, pixel[0], pixel[1], pixel[2], pixel[3], correct ? "PASS" : "FAIL");
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
    ID3D11RenderTargetView_Release(view); ID3D11Texture2D_Release(staging);
    ID3D11Texture2D_Release(target); ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    return !correct;
}

static int d3d12_probe(void) {
    ID3D12Device *device = NULL;
    CHECK(D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device));
    D3D12_COMMAND_QUEUE_DESC qdesc = {0};
    ID3D12CommandQueue *queue = NULL;
    ID3D12CommandAllocator *allocator = NULL;
    ID3D12GraphicsCommandList *list = NULL;
    CHECK(ID3D12Device_CreateCommandQueue(device, &qdesc, &IID_ID3D12CommandQueue, (void **)&queue));
    CHECK(ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                             &IID_ID3D12CommandAllocator, (void **)&allocator));
    CHECK(ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                        allocator, NULL, &IID_ID3D12GraphicsCommandList, (void **)&list));
    D3D12_HEAP_PROPERTIES heap = {0}; heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC desc = {0};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; desc.Width = desc.Height = 4;
    desc.DepthOrArraySize = desc.MipLevels = 1; desc.SampleDesc.Count = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    ID3D12Resource *target = NULL, *readback = NULL;
    CHECK(ID3D12Device_CreateCommittedResource(device, &heap, D3D12_HEAP_FLAG_NONE,
        &desc, D3D12_RESOURCE_STATE_RENDER_TARGET, NULL, &IID_ID3D12Resource, (void **)&target));
    D3D12_DESCRIPTOR_HEAP_DESC dhdesc = {0};
    dhdesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV; dhdesc.NumDescriptors = 1;
    ID3D12DescriptorHeap *dheap = NULL;
    CHECK(ID3D12Device_CreateDescriptorHeap(device, &dhdesc, &IID_ID3D12DescriptorHeap, (void **)&dheap));
    D3D12_CPU_DESCRIPTOR_HANDLE handle = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(dheap);
    ID3D12Device_CreateRenderTargetView(device, target, NULL, handle);
    const FLOAT color[] = {0.f, 1.f, 0.f, 1.f};
    ID3D12GraphicsCommandList_ClearRenderTargetView(list, handle, color, 0, NULL);
    D3D12_RESOURCE_BARRIER barrier = {0};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = target;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &barrier);
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    UINT64 size;
    ID3D12Device_GetCopyableFootprints(device, &desc, 0, 1, 0, &footprint, NULL, NULL, &size);
    heap.Type = D3D12_HEAP_TYPE_READBACK;
    desc = (D3D12_RESOURCE_DESC){0};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; desc.Width = size;
    desc.Height = desc.DepthOrArraySize = desc.MipLevels = desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    CHECK(ID3D12Device_CreateCommittedResource(device, &heap, D3D12_HEAP_FLAG_NONE,
        &desc, D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&readback));
    D3D12_TEXTURE_COPY_LOCATION from = {0}, to = {0};
    from.pResource = target; from.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    to.pResource = readback; to.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    to.PlacedFootprint = footprint;
    ID3D12GraphicsCommandList_CopyTextureRegion(list, &to, 0, 0, 0, &from, NULL);
    CHECK(ID3D12GraphicsCommandList_Close(list));
    ID3D12CommandList *commands[] = {(ID3D12CommandList *)list};
    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, commands);
    ID3D12Fence *fence = NULL;
    CHECK(ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence));
    HANDLE event = CreateEventA(NULL, FALSE, FALSE, NULL);
    CHECK(ID3D12CommandQueue_Signal(queue, fence, 1));
    CHECK(ID3D12Fence_SetEventOnCompletion(fence, 1, event));
    if (WaitForSingleObject(event, 15000) != WAIT_OBJECT_0) { puts("FAIL GPU fence timeout"); return 1; }
    unsigned char *data;
    D3D12_RANGE range = {0, (SIZE_T)size};
    CHECK(ID3D12Resource_Map(readback, 0, &range, (void **)&data));
    unsigned char *pixel = data + footprint.Offset;
    int correct = pixel[0] == 0 && pixel[1] == 255 && pixel[2] == 0 && pixel[3] == 255;
    printf("D3D12 GPU readback RGBA=%u,%u,%u,%u %s\n",
           pixel[0], pixel[1], pixel[2], pixel[3], correct ? "PASS" : "FAIL");
    D3D12_RANGE written = {0, 0}; ID3D12Resource_Unmap(readback, 0, &written);
    CloseHandle(event); ID3D12Fence_Release(fence); ID3D12DescriptorHeap_Release(dheap);
    ID3D12Resource_Release(readback); ID3D12Resource_Release(target);
    ID3D12GraphicsCommandList_Release(list); ID3D12CommandAllocator_Release(allocator);
    ID3D12CommandQueue_Release(queue); ID3D12Device_Release(device);
    return !correct;
}

static int steam_probe(const char *dll, unsigned expected) {
    HMODULE api = LoadLibraryA(dll);
    if (!api) { printf("FAIL Steam API load error=%lu\n", GetLastError()); return 1; }
    int (*init)(char *) = (void *)GetProcAddress(api, "SteamAPI_InitFlat");
    void (*shutdown)(void) = (void *)GetProcAddress(api, "SteamAPI_Shutdown");
    void *(*utils)(void) = (void *)GetProcAddress(api, "SteamAPI_SteamUtils_v010");
    unsigned (*appid)(void *) = (void *)GetProcAddress(api, "SteamAPI_ISteamUtils_GetAppID");
    void *(*user)(void) = (void *)GetProcAddress(api, "SteamAPI_SteamUser_v023");
    unsigned char (*online)(void *) = (void *)GetProcAddress(api, "SteamAPI_ISteamUser_BLoggedOn");
    if (!init || !shutdown || !utils || !appid || !user || !online) { puts("FAIL API exports"); return 1; }
    char error[1024] = {0}; int code = init(error);
    if (code) { printf("FAIL SteamAPI_InitFlat=%d %s\n", code, error); return 1; }
    void *u = utils(), *s = user();
    unsigned actual = u ? appid(u) : 0;
    int logged = s ? online(s) : 0;
    int correct = actual == expected && logged;
    printf("SteamAPI init=0 AppID=%u expected=%u logged_on=%d %s (read-only)\n",
           actual, expected, logged, correct ? "PASS" : "FAIL");
    fflush(stdout); Sleep(8000); shutdown(); FreeLibrary(api);
    return !correct;
}

int main(int argc, char **argv) {
    const char *result_file = getenv("FLUENT_PROBE_RESULT");
    if (result_file && !freopen(result_file, "w", stdout)) return 3;
    setvbuf(stdout, NULL, _IONBF, 0);
    int result;
    if (argc == 2 && !strcmp(argv[1], "11")) result = d3d11_probe();
    else if (argc == 2 && !strcmp(argv[1], "12")) result = d3d12_probe();
    else if (argc == 4 && !strcmp(argv[1], "steam")) result = steam_probe(argv[2], strtoul(argv[3], NULL, 10));
    else { fputs("Usage: probe.exe 11|12|steam <steam_api64.dll> <appid>\n", stderr); return 2; }
    fflush(stdout); Sleep(5000);
    return result;
}
