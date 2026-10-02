// Executed in the extracted artifact; compiled outside it and never shipped.
#include <clocale>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <netdb.h>
#include <pwd.h>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <atomic>
int main() {
    if (!setlocale(LC_ALL, "C.UTF-8")) { std::fputs("missing C.UTF-8 locale data\n", stderr); return 1; }
    if (!getpwnam("root")) return 2;
    addrinfo* addresses = nullptr;
    if (getaddrinfo("localhost", nullptr, nullptr, &addresses)) return 3;
    freeaddrinfo(addresses);
    std::atomic<int> value{0};
    std::thread worker([&] { value = 42; }); worker.join();
    if (value != 42) return 4;
    try { throw std::runtime_error("unwind works"); }
    catch (const std::exception& e) { if (std::strcmp(e.what(), "unwind works")) return 5; }
    void* z = dlopen("libz.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!z) { std::fprintf(stderr, "%s\n", dlerror()); return 6; }
    auto version = reinterpret_cast<const char*(*)()>(dlsym(z, "zlibVersion"));
    if (!version || !version()[0]) return 7;
    dlclose(z);
    auto* ca = std::fopen("/etc/ssl/certs/ca-certificates.crt", "r");
    if (!ca) return 8;
    std::fclose(ca);
    std::puts("PASS: glibc loader, C.UTF-8, NSS, pthread, C++ unwind, dlopen(zlib), CA bundle");
}
