// Real COM/Win32 integration tests. This exe also acts as a harmless launch
// recorder when copied to the test installation as wispterm.exe.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <servprov.h>
#include <string>
#include <iostream>
#include "command_line.h"

#define CHECK(value) do { if (!(value)) { std::cerr << "FAILED line " << __LINE__ << ": " #value "\n"; return 1; } } while (0)
#define OK(call) CHECK(SUCCEEDED(call))
template<class T> struct Ptr { T* p=nullptr; ~Ptr(){if(p)p->Release();} T* operator->(){return p;} T** put(){return &p;} };
static std::wstring cwd() { std::wstring s(32768,L'\0'); s.resize(GetCurrentDirectoryW(static_cast<DWORD>(s.size()),s.data())); return s; }
static int record(const wchar_t* dir) {
    std::wstring data = std::wstring(dir) + L"\n" + cwd();
    HANDLE f = CreateFileW((std::wstring(dir)+L"\\wispterm-shell-launch.txt").c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, 0, nullptr);
    if(f==INVALID_HANDLE_VALUE)return 2;
    DWORD written=0;
    bool ok=WriteFile(f,data.data(),static_cast<DWORD>(data.size()*sizeof(wchar_t)),&written,nullptr);
    CloseHandle(f);
    return ok?0:2;
}
static bool waitRecord(const std::wstring& dir) {
    const auto expected=dir+L"\n"+dir;
    for(int i=0;i<100;++i) {
        HANDLE f=CreateFileW((dir+L"\\wispterm-shell-launch.txt").c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,0,nullptr);
        if(f!=INVALID_HANDLE_VALUE) {
            std::wstring data(32768,L'\0'); DWORD n=0;
            ReadFile(f,data.data(),static_cast<DWORD>(data.size()*sizeof(wchar_t)),&n,nullptr); CloseHandle(f);
            data.resize(n/sizeof(wchar_t));
            if(data==expected)return true;
        }
        Sleep(50);
    }
    return false;
}
class Site final : public IServiceProvider {
    LONG refs=1; IFolderView* view;
public:
    explicit Site(IFolderView* v):view(v){view->AddRef();}
    ~Site(){view->Release();}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out) override {
        *out=nullptr;
        if(iid!=IID_IUnknown && iid!=IID_IServiceProvider)return E_NOINTERFACE;
        *out=static_cast<IServiceProvider*>(this);AddRef();return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override {return InterlockedIncrement(&refs);}
    ULONG STDMETHODCALLTYPE Release() override {LONG n=InterlockedDecrement(&refs);if(!n)delete this;return n;}
    HRESULT STDMETHODCALLTYPE QueryService(REFGUID service,REFIID iid,void** out) override {
        *out=nullptr;if(service!=SID_SFolderView)return E_NOINTERFACE;return view->QueryInterface(iid,out);
    }
};
static int run(const wchar_t* source) {
    for(const auto& arg : {L"C:\\",L"C:\\space & percent %\\",L"\\\\server\\share\\中文",L"C:\\a\"b\\",L""}) {
        const auto line=wispterm::launchCommand(L"C:\\App Space\\wispterm.exe",arg);
        int count=0; LPWSTR* parsed=CommandLineToArgvW(line.c_str(),&count);
        CHECK(parsed && count==3 && std::wstring(parsed[1])==L"--working-directory" && std::wstring(parsed[2])==arg);
        LocalFree(parsed);
    }
    const bool registered=std::wstring(source)==L"--registered";
    CLSID clsid; OK(CLSIDFromString(L"{22FE0F26-8C15-4BC6-A6F7-3C88F4E20A71}",&clsid));
    Ptr<IExplorerCommand> command;
    HMODULE dll=nullptr;
    using Unload=HRESULT (WINAPI*)();
    Unload canUnload=nullptr;
    if(registered) {
        OK(CoCreateInstance(clsid,nullptr,CLSCTX_LOCAL_SERVER,IID_IExplorerCommand,reinterpret_cast<void**>(command.put())));
    } else {
        dll=LoadLibraryW(source);CHECK(dll);
        auto getClass=reinterpret_cast<HRESULT (WINAPI*)(REFCLSID,REFIID,void**)>(GetProcAddress(dll,"DllGetClassObject"));
        canUnload=reinterpret_cast<Unload>(GetProcAddress(dll,"DllCanUnloadNow"));
        CHECK(getClass && canUnload && canUnload()==S_OK);
        Ptr<IClassFactory> factory;
        CHECK(getClass(CLSID_NULL,IID_IClassFactory,reinterpret_cast<void**>(factory.put()))==CLASS_E_CLASSNOTAVAILABLE);
        OK(getClass(clsid,IID_IClassFactory,reinterpret_cast<void**>(factory.put())));
        CHECK(canUnload()==S_FALSE);
        CHECK(factory->CreateInstance(factory.p,IID_IExplorerCommand,reinterpret_cast<void**>(command.put()))==CLASS_E_NOAGGREGATION);
        OK(factory->CreateInstance(nullptr,IID_IExplorerCommand,reinterpret_cast<void**>(command.put())));
        OK(factory->LockServer(TRUE)); OK(factory->LockServer(FALSE));
    }
    PWSTR text=nullptr; OK(command->GetTitle(nullptr,&text));CHECK(text && *text);CoTaskMemFree(text);
    OK(command->GetIcon(nullptr,&text));std::wstring ownExe(32768,L'\0');ownExe.resize(GetModuleFileNameW(nullptr,ownExe.data(),static_cast<DWORD>(ownExe.size())));
    CHECK(_wcsicmp(text,(ownExe+L",-1").c_str())==0);CoTaskMemFree(text);
    EXPCMDSTATE state;OK(command->GetState(nullptr,FALSE,&state));CHECK(state==ECS_HIDDEN);
    GUID canonical;OK(command->GetCanonicalName(&canonical));CHECK(canonical==clsid);
    EXPCMDFLAGS flags;OK(command->GetFlags(&flags));CHECK(flags==ECF_DEFAULT);
    IEnumExplorerCommand* sub=nullptr;CHECK(command->EnumSubCommands(&sub)==E_NOTIMPL && !sub);
    const auto dir=cwd()+L"\\folder 中文 & % test";
    CHECK(CreateDirectoryW(dir.c_str(),nullptr) || GetLastError()==ERROR_ALREADY_EXISTS);
    Ptr<IShellItem> item;OK(SHCreateItemFromParsingName(dir.c_str(),nullptr,IID_IShellItem,reinterpret_cast<void**>(item.put())));
    Ptr<IShellItemArray> selection;OK(SHCreateShellItemArrayFromShellItem(item.p,IID_IShellItemArray,reinterpret_cast<void**>(selection.put())));
    OK(command->GetState(selection.p,FALSE,&state));CHECK(state==ECS_ENABLED);
    DeleteFileW((dir+L"\\wispterm-shell-launch.txt").c_str());
    OK(command->Invoke(selection.p,nullptr));CHECK(waitRecord(dir));

    // A multi-selection must not silently launch only its first item.
    PIDLIST_ABSOLUTE id=nullptr;OK(SHGetIDListFromObject(item.p,&id));
    PCIDLIST_ABSOLUTE ids[]={id,id};Ptr<IShellItemArray> multi;
    OK(SHCreateShellItemArrayFromIDLists(2,ids,multi.put()));CoTaskMemFree(id);
    OK(command->GetState(multi.p,FALSE,&state));CHECK(state==ECS_HIDDEN);
    CHECK(FAILED(command->Invoke(multi.p,nullptr)));

    const auto file=dir+L"\\wispterm-shell-launch.txt";
    Ptr<IShellItem> fileItem;OK(SHCreateItemFromParsingName(file.c_str(),nullptr,IID_IShellItem,reinterpret_cast<void**>(fileItem.put())));
    Ptr<IShellItemArray> fileSelection;OK(SHCreateShellItemArrayFromShellItem(fileItem.p,IID_IShellItemArray,reinterpret_cast<void**>(fileSelection.put())));
    OK(command->GetState(fileSelection.p,FALSE,&state));CHECK(state==ECS_HIDDEN);
    if(!registered) {
        // Obtain an actual folder view without creating an Explorer window.
        Ptr<IShellFolder> folder;OK(item->BindToHandler(nullptr,BHID_SFObject,IID_IShellFolder,reinterpret_cast<void**>(folder.put())));
        Ptr<IShellView> shellView;OK(folder->CreateViewObject(nullptr,IID_IShellView,reinterpret_cast<void**>(shellView.put())));
        Ptr<IFolderView> view;OK(shellView->QueryInterface(IID_IFolderView,reinterpret_cast<void**>(view.put())));
        Ptr<IObjectWithSite> withSite;OK(command->QueryInterface(IID_IObjectWithSite,reinterpret_cast<void**>(withSite.put())));
        auto site=new Site(view.p);OK(withSite->SetSite(site));site->Release();
        OK(command->GetState(nullptr,FALSE,&state));CHECK(state==ECS_ENABLED);
        DeleteFileW(file.c_str());OK(command->Invoke(nullptr,nullptr));CHECK(waitRecord(dir));
        OK(withSite->SetSite(nullptr));OK(command->GetState(nullptr,FALSE,&state));CHECK(state==ECS_HIDDEN);
    }
    command.p->Release();command.p=nullptr;
    if(canUnload){CHECK(canUnload()==S_OK);FreeLibrary(dll);}
    std::cout << "PASS: COM activation, folder/background selection, launch argv/cwd, quoting and lifetime\n";
    return 0;
}
int main() {
    int count=0;LPWSTR* args=CommandLineToArgvW(GetCommandLineW(),&count);
    if(count==3 && std::wstring(args[1])==L"--working-directory")return record(args[2]);
    if(count!=2)return 2;
    if(FAILED(CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED)))return 2;
    int result=run(args[1]);LocalFree(args);CoUninitialize();return result;
}
