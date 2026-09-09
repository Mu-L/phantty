#pragma once
#include <string>

namespace wispterm {
// Windows argv quoting, including the doubled trailing slash in a drive root.
// Launch directly with CreateProcessW: directory names never become shell code.
inline std::wstring quoteArgument(const std::wstring& value) {
    std::wstring out = L"\"";
    size_t slashes = 0;
    for (wchar_t ch : value) {
        if (ch == L'\\') { ++slashes; continue; }
        out.append(slashes * (ch == L'"' ? 2 : 1), L'\\');
        slashes = 0;
        if (ch == L'"') out.push_back(L'\\');
        out.push_back(ch);
    }
    out.append(slashes * 2, L'\\');
    out.push_back(L'"');
    return out;
}
inline std::wstring launchCommand(const std::wstring& exe, const std::wstring& directory) {
    return quoteArgument(exe) + L" --working-directory " + quoteArgument(directory);
}
}
