// Explorer integration is a separate COM DLL; it never loads the terminal core.
// Like Ghostty's directory services and Windows Terminal's OpenTerminalHere,
// this adapter passes a filesystem directory to the existing launch API.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <servprov.h>
#include <new>
#include <string>
#include "command_line.h"

// Keep in sync with packaging/windows/shell-integration/AppxManifest.xml.
static const CLSID commandId = {0x22fe0f26,0x8c15,0x4bc6,{0xa6,0xf7,0x3c,0x88,0xf4,0xe2,0x0a,0x71}};
static HMODULE module;
static LONG objects = 0;
static LONG locks = 0;

template<class T> struct ComPtr {
    T* p = nullptr;
    ~ComPtr() { if (p) p->Release(); }
    T* operator->() const { return p; }
    T** put() { return &p; }
};
struct ShellString {
    PWSTR p = nullptr;
    ~ShellString() { CoTaskMemFree(p); }
};

// The DLL is stored in <install>/shell-integration/<version-hash>/.
static HRESULT executablePath(std::wstring& out) {
    std::wstring path(32768, L'\0');
    DWORD n = GetModuleFileNameW(module, path.data(), static_cast<DWORD>(path.size()));
    if (!n) return HRESULT_FROM_WIN32(GetLastError());
    if (n >= path.size()) return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
    path.resize(n);
    for (int i = 0; i < 3; ++i) {
        auto slash = path.find_last_of(L"\\/");
        if (slash == std::wstring::npos) return E_UNEXPECTED;
        path.resize(slash);
    }
    out = path + L"\\wispterm.exe";
    return S_OK;
}

class Command final : public IExplorerCommand, public IObjectWithSite {
    LONG refs = 1;
    IUnknown* site = nullptr;
public:
    Command() { InterlockedIncrement(&objects); }
    ~Command() { if (site) site->Release(); InterlockedDecrement(&objects); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (IsEqualIID(iid, IID_IUnknown) || IsEqualIID(iid, IID_IExplorerCommand))
            *out = static_cast<IExplorerCommand*>(this);
        else if (IsEqualIID(iid, IID_IObjectWithSite)) *out = static_cast<IObjectWithSite*>(this);
        else return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG n = InterlockedDecrement(&refs);
        if (!n) delete this;
        return n;
    }
    HRESULT STDMETHODCALLTYPE SetSite(IUnknown* value) override {
        if (value) value->AddRef();
        if (site) site->Release();
        site = value;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetSite(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        return site ? site->QueryInterface(iid, out) : E_FAIL;
    }
    HRESULT location(IShellItemArray* selection, IShellItem** out) {
        *out = nullptr;
        if (selection) {
            DWORD count = 0;
            HRESULT hr = selection->GetCount(&count);
            if (FAILED(hr)) return hr;
            if (count > 1) return E_INVALIDARG;
            if (count == 1) return selection->GetItemAt(0, out);
        }
        // Explorer's background menu has no selected item. Its site exposes
        // the current folder through SID_SFolderView, including UNC folders.
        if (!site) return E_FAIL;
        ComPtr<IServiceProvider> services;
        HRESULT hr = site->QueryInterface(IID_IServiceProvider, reinterpret_cast<void**>(services.put()));
        if (FAILED(hr)) return hr;
        ComPtr<IFolderView> view;
        hr = services->QueryService(SID_SFolderView, IID_IFolderView, reinterpret_cast<void**>(view.put()));
        if (FAILED(hr)) return hr;
        return view->GetFolder(IID_IShellItem, reinterpret_cast<void**>(out));
    }
    HRESULT STDMETHODCALLTYPE GetTitle(IShellItemArray*, LPWSTR* out) override {
        if (!out) return E_POINTER;
        return SHStrDupW(PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE
            ? L"在 WispTerm 中打开" : L"Open in WispTerm", out);
    }
    HRESULT STDMETHODCALLTYPE GetIcon(IShellItemArray*, LPWSTR* out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        try {
            std::wstring exe;
            HRESULT hr = executablePath(exe);
            if (FAILED(hr)) return hr;
            return SHStrDupW((exe + L",-1").c_str(), out);
        } catch (const std::bad_alloc&) { return E_OUTOFMEMORY; }
          catch (...) { return E_FAIL; }
    }
    HRESULT STDMETHODCALLTYPE GetToolTip(IShellItemArray*, LPWSTR* out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE GetCanonicalName(GUID* out) override {
        if (!out) return E_POINTER;
        *out = commandId;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetState(IShellItemArray* selection, BOOL, EXPCMDSTATE* out) override {
        if (!out) return E_POINTER;
        *out = ECS_HIDDEN;
        ComPtr<IShellItem> item;
        if (FAILED(location(selection, item.put())) || !item.p) return S_OK;
        SFGAOF attrs = 0;
        const SFGAOF required = SFGAO_FILESYSTEM | SFGAO_FOLDER;
        // Attribute-only check: never spawn, probe disks, or load WispTerm
        // while Explorer is constructing a context menu.
        if (SUCCEEDED(item->GetAttributes(required | SFGAO_STREAM, &attrs)) &&
            (attrs & required) == required && !(attrs & SFGAO_STREAM)) *out = ECS_ENABLED;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Invoke(IShellItemArray* selection, IBindCtx*) override {
        try {
            EXPCMDSTATE state;
            HRESULT hr = GetState(selection, FALSE, &state);
            if (FAILED(hr)) return hr;
            if (state != ECS_ENABLED) return E_INVALIDARG;
            ComPtr<IShellItem> item;
            hr = location(selection, item.put());
            if (FAILED(hr)) return hr;
            ShellString folder;
            hr = item->GetDisplayName(SIGDN_FILESYSPATH, &folder.p);
            if (FAILED(hr)) return hr;
            std::wstring exe;
            hr = executablePath(exe);
            if (FAILED(hr)) return hr;
            std::wstring args = wispterm::launchCommand(exe, folder.p);
            STARTUPINFOW si{};
            si.cb = sizeof(si);
            si.dwFlags = STARTF_USESHOWWINDOW;
            si.wShowWindow = SW_SHOWNORMAL;
            PROCESS_INFORMATION pi{};
            if (!CreateProcessW(exe.c_str(), args.data(), nullptr, nullptr, FALSE,
                                CREATE_UNICODE_ENVIRONMENT, nullptr, folder.p, &si, &pi))
                return HRESULT_FROM_WIN32(GetLastError());
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            return S_OK;
        } catch (const std::bad_alloc&) { return E_OUTOFMEMORY; }
          catch (...) { return E_FAIL; }
    }
    HRESULT STDMETHODCALLTYPE GetFlags(EXPCMDFLAGS* out) override {
        if (!out) return E_POINTER;
        *out = ECF_DEFAULT;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE EnumSubCommands(IEnumExplorerCommand** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        return E_NOTIMPL;
    }
};

class Factory final : public IClassFactory {
    LONG refs = 1;
public:
    Factory() { InterlockedIncrement(&objects); }
    ~Factory() { InterlockedDecrement(&objects); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (!IsEqualIID(iid, IID_IUnknown) && !IsEqualIID(iid, IID_IClassFactory)) return E_NOINTERFACE;
        *out = static_cast<IClassFactory*>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG n = InterlockedDecrement(&refs);
        if (!n) delete this;
        return n;
    }
    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        auto command = new (std::nothrow) Command;
        if (!command) return E_OUTOFMEMORY;
        HRESULT hr = command->QueryInterface(iid, out);
        command->Release();
        return hr;
    }
    HRESULT STDMETHODCALLTYPE LockServer(BOOL lock) override {
        if (lock) InterlockedIncrement(&locks); else InterlockedDecrement(&locks);
        return S_OK;
    }
};

extern "C" __declspec(dllexport) HRESULT WINAPI DllGetClassObject(REFCLSID clsid, REFIID iid, void** out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (!IsEqualCLSID(clsid, commandId)) return CLASS_E_CLASSNOTAVAILABLE;
    auto factory = new (std::nothrow) Factory;
    if (!factory) return E_OUTOFMEMORY;
    HRESULT hr = factory->QueryInterface(iid, out);
    factory->Release();
    return hr;
}
extern "C" __declspec(dllexport) HRESULT WINAPI DllCanUnloadNow() {
    return InterlockedCompareExchange(&objects, 0, 0) == 0 &&
           InterlockedCompareExchange(&locks, 0, 0) == 0 ? S_OK : S_FALSE;
}
extern "C" BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) module = instance;
    return TRUE;
}
