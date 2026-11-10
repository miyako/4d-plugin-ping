#include "4DPluginAPI.h"
#include "PrivateTypes.h"
#include "EntryPoints.h"
#include "4DPlugin.h"
#include <codecvt>
#include <cstring>
#include <iostream>
#include <locale>
#include <stdexcept>

static std::map<PA_Unichar*, size_t> strings;
static std::map<PA_Picture, int> pictures;
static std::map<PA_Handle, size_t> handles;
static bool nullEmpty, failHandle, failCommand, failPointer, failResize, failConversion, failCreation;
static int commandCalls, resultKind = 1, networkMode, socketCalls, closeCalls, sends, receives, frees;
static int openSockets, clockCalls;
static CUTF16String expected;

static void check(bool valid, const char* message)
{
    if (!valid) { std::cerr << message << "\n"; std::exit(1); }
}

static CUTF16String utf16(const char* text)
{
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> codec;
    auto converted = codec.from_bytes(text);
    return CUTF16String(reinterpret_cast<const PA_Unichar*>(converted.data()), converted.size());
}

static PA_Unistring makeString(const PA_Unichar* text)
{
    size_t units = 0;
    while (text && text[units]) ++units;
    PA_Unistring value = {};
    if (units || !nullEmpty) {
        value.fString = new PA_Unichar[units + 1];
        if (units) std::memcpy(value.fString, text, units * sizeof(PA_Unichar));
        value.fString[units] = 0;
        value.fLength = static_cast<PA_long32>(units);
        strings[value.fString] = units;
    }
    return value;
}

static void disposeString(PA_Unistring value)
{
    if (!value.fString) { check(value.fLength == 0, "null nonempty string"); return; }
    check(strings.count(value.fString), "duplicate/unowned string disposal");
    check(strings.at(value.fString) == static_cast<size_t>(value.fLength), "allocation length");
    strings.erase(value.fString);
    delete[] value.fString;
}

static void textEquals(PA_Unistring value, const CUTF16String& wanted)
{
    check(value.fLength == static_cast<PA_long32>(wanted.size()), "exact UTF16 length");
    check(value.fString || wanted.empty(), "missing text allocation");
    if (value.fString) {
        check(strings.count(value.fString), "read after string release");
        check(value.fString[value.fLength] == 0, "text terminator");
        check(CUTF16String(value.fString, value.fLength) == wanted, "exact UTF16 content");
    }
}

static PA_Picture makePicture()
{
    PA_Picture p = new unsigned char(42);
    pictures[p] = 1;
    return p;
}

static void releasePicture(PA_Picture p)
{
    if (!p) return;
    check(pictures.count(p), "duplicate/unowned picture disposal");
    if (--pictures[p] == 0) { pictures.erase(p); delete static_cast<unsigned char*>(p); }
}

static void clear(PA_Variable* v)
{
    if (v->fType == eVK_Unistring) disposeString(v->uValue.fString);
    else if (v->fType == eVK_Picture) releasePicture(v->uValue.fPicture);
    else if (v->fType == eVK_ArrayUnicode) {
        auto h = v->uValue.fArray.fData;
        check(handles.count(h), "invalid array handle");
        auto values = reinterpret_cast<PA_Unistring*>(*h);
        for (PA_long32 i = 0; i <= v->uValue.fArray.fNbElements; ++i) disposeString(values[i]);
        std::free(*h); delete h; handles.erase(h);
    } else check(v->fType == eVK_Undefined || v->fType == eVK_Longint,
                 "unsupported clear kind (including raw-kind0 failure sentinel)");
    v->fType = eVK_Undefined;
    v->fFiller = 0;
}

static void host(short selector, EngineBlock* eb)
{
    switch (selector) {
    case EX_CREATE_UNISTRING:
        eb->fUniString1 = makeString(reinterpret_cast<PA_Unichar*>(eb->fHandle)); break;
    case EX_DISPOSE_UNISTRING: disposeString(eb->fUniString1); break;
    case EX_SET_UNISTRING: {
        auto replacement = makeString(reinterpret_cast<PA_Unichar*>(eb->fHandle));
        disposeString(eb->fUniString1); eb->fUniString1 = replacement; break;
    }
    case EX_CREATE_PICTURE:
        if (failCreation) {
            eb->fPicture = reinterpret_cast<PA_Picture>(1);
            eb->fError = eER_IncompatibleTypes; break;
        }
        check(eb->fParam1 == 0 || eb->fPtr1, "picture bytes missing");
        eb->fPicture = makePicture(); eb->fError = 0; break;
    case EX_DISPOSE_PICTURE: releasePicture(eb->fPicture); break;
    case EX_DUPLICATE_PICTURE:
        if (!eb->fPicture) break;
        check(pictures.count(eb->fPicture), "retain dead picture");
        if (eb->fParam1 == 0) ++pictures[eb->fPicture];
        else eb->fPicture = makePicture();
        break;
    case EX_GET_PICTURE_DATA:
        check(pictures.count(eb->fPicture), "enumerate dead picture");
        eb->fError = eER_IncompatibleTypes;
        // This SDK does not specify metadata ownership. No success ownership claim.
        eb->fUniString1.fLength = -1;
        eb->fUniString1.fString = reinterpret_cast<PA_Unichar*>(1);
        break;
    case EX_CLEAR_VARIABLE: clear(static_cast<PA_Variable*>(eb->fPtr1)); break;
    case EX_GET_INFORMATION: eb->fParam1 = 0; break;
    case EX_YIELD_ABSOLUTE: break;
    case EX_GET_POINTER_VALUE_PROPERTIES:
        eb->fParam1 = eVK_Unistring; eb->fParam2 = 0; eb->fParam3 = 0; eb->fError = 0; break;
    case EX_GET_POINTER_VALUE:
        if (failPointer) {
            std::memset(eb->fHandle, 0xa5, sizeof(PA_Variable));
            eb->fError = eER_IncompatibleTypes;
        } else {
            auto v = reinterpret_cast<PA_Variable*>(eb->fHandle);
            *v = PA_CreateVariable(eVK_Undefined);
            auto owned = makeString(expected.c_str());
            PA_SetStringVariable(v, &owned);
            eb->fError = 0;
        }
        break;
    case EX_HANDLE_MANAGER: {
        auto h = eb->fHandle;
        switch (eb->fParam1) {
        case 1:
            if (failHandle) { eb->fHandle = nullptr; eb->fError = eER_IncompatibleTypes; break; }
            h = new char*;
            *h = static_cast<char*>(std::calloc(1, std::max<sLONG_PTR>(1, eb->fParam2)));
            check(*h, "test handle allocation failed");
            handles[h] = eb->fParam2; eb->fHandle = h; break;
        case 2:
            check(handles.count(h), "dispose dead handle");
            std::free(*h); delete h; handles.erase(h); break;
        case 3: {
            check(handles.count(h), "resize dead handle");
            if (failResize) { eb->fError = eER_IncompatibleTypes; break; }
            auto data = static_cast<char*>(std::realloc(*h, std::max<sLONG_PTR>(1, eb->fParam2)));
            check(data, "test resize allocation failed");
            *h = data; handles[h] = eb->fParam2; break;
        }
        case 4: check(handles.count(h), "size dead handle"); eb->fParam2 = handles[h]; break;
        case 5:
            check(handles.count(h), "lock dead handle");
            eb->fParam3 = reinterpret_cast<sLONG_PTR>(*h); break;
        case 6: check(handles.count(h), "unlock dead handle"); break;
        default: check(false, "unexpected handle operation");
        }
        break;
    }
    case EX_CONVERT_CHARSET_TO_CHARSET: {
        if (failConversion) { eb->fError = eER_IncompatibleTypes; break; }
        std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> codec;
        size_t bytes;
        if (eb->fParam2 == eVTC_UTF_8 && eb->fParam4 == eVTC_UTF_16) {
            auto in = static_cast<char*>(eb->fPtr1);
            auto out = codec.from_bytes(in, in + eb->fParam1);
            bytes = out.size() * sizeof(PA_Unichar);
            check(bytes + sizeof(PA_Unichar) <= static_cast<size_t>(eb->fParam3), "UTF16 capacity");
            std::memcpy(eb->fPtr2, out.data(), bytes);
            std::memset(static_cast<char*>(eb->fPtr2) + bytes, 0, sizeof(PA_Unichar));
        } else {
            check(eb->fParam2 == eVTC_UTF_16 && eb->fParam4 == eVTC_UTF_8, "conversion direction");
            auto in = static_cast<char16_t*>(eb->fPtr1);
            auto out = codec.to_bytes(in, in + eb->fParam1 / sizeof(PA_Unichar));
            bytes = out.size();
            check(bytes + 1 <= static_cast<size_t>(eb->fParam3), "UTF8 capacity");
            std::memcpy(eb->fPtr2, out.data(), bytes);
            static_cast<char*>(eb->fPtr2)[bytes] = 0;
        }
        eb->fParam3 = bytes; eb->fError = 0; break;
    }
    case EX_EXECUTE_COMMAND_BY_ID: {
        ++commandCalls;
        auto args = static_cast<PA_Variable**>(eb->fPtr1);
        auto result = static_cast<PA_Variable*>(eb->fPtr2);
        check(result->fType == eVK_Undefined, "command return initialization");
        if (failCommand) {
            std::memset(result, 0xa5, sizeof(*result));
            eb->fError = eER_IncompatibleTypes; break;
        }
        if (eb->fParam1 == 678) {
            textEquals(args[0]->uValue.fString, expected);
            clear(args[1]); PA_SetPictureVariable(args[1], makePicture());
        } else if (eb->fParam1 == 1002) {
            textEquals(args[1]->uValue.fString, expected);
            clear(args[0]); PA_SetPictureVariable(args[0], makePicture());
        } else if (eb->fParam1 == 988) {
            clear(args[0]); PA_SetPictureVariable(args[0], makePicture());
        } else if (eb->fParam1 == 457) {
            check(pictures.count(args[0]->uValue.fPicture), "size input dead");
            PA_SetLongintVariable(args[1], 23); PA_SetLongintVariable(args[2], 17);
        } else if (eb->fParam1 == 679) {
            check(pictures.count(args[0]->uValue.fPicture), "thumbnail input dead");
            clear(args[1]); PA_SetPictureVariable(args[1], makePicture());
        } else check(false, "unexpected command");
        if (resultKind == 1) {
            auto owned = makeString(expected.c_str()); PA_SetStringVariable(result, &owned);
        } else if (resultKind == 2) PA_SetPictureVariable(result, makePicture());
        eb->fError = 0; break;
    }
    default:
        std::cerr << "unexpected engine selector " << selector << "\n"; std::exit(1);
    }
}

@implementation OwnershipURL
- (id)initWithString:(NSString *)value { return [super init]; }
- (NSString *)absoluteString { return @"synthetic"; }
@end
@implementation OwnershipImage
- (id)initWithCGImage:(CGImageRef)image size:(NSSize)size { return [super init]; }
- (NSData *)TIFFRepresentation { return [NSData dataWithBytes:"123" length:3]; }
@end
CFURLRef OwnershipCreateURL(CFAllocatorRef, CFStringRef, CFURLPathStyle, Boolean)
{ return reinterpret_cast<CFURLRef>([[OwnershipURL alloc] init]); }
CFStringRef OwnershipCopyPath(CFURLRef, CFURLPathStyle)
{ return reinterpret_cast<CFStringRef>([[NSString alloc] initWithString:@"synthetic"]); }

static struct sockaddr_in syntheticAddress;
static struct addrinfo syntheticInfo;
int OwnershipGetAddrInfo(const char* node, const char* service, const struct addrinfo*, struct addrinfo** out)
{
    check(std::string(node) == "synthetic.invalid" && !service, "unexpected DNS input");
    if (networkMode == 2) return EAI_NONAME;
    syntheticAddress = {};
    syntheticAddress.sin_family = AF_INET;
    syntheticInfo = {};
    syntheticInfo.ai_family = AF_INET;
    syntheticInfo.ai_socktype = SOCK_STREAM;
    syntheticInfo.ai_addr = reinterpret_cast<sockaddr*>(&syntheticAddress);
    syntheticInfo.ai_addrlen = sizeof(syntheticAddress);
    *out = &syntheticInfo;
    return 0;
}
void OwnershipFreeAddrInfo(struct addrinfo* value)
{ check(value == &syntheticInfo, "unexpected DNS release"); ++frees; }
int OwnershipSocket(int family, int kind, int protocol)
{
    check(family == AF_INET, "unexpected socket family");
    ++socketCalls;
    check((kind == SOCK_STREAM && protocol == 0) ||
          (kind == SOCK_DGRAM && protocol == IPPROTO_ICMP), "unexpected socket");
    if (networkMode == 3 || (networkMode == 4 && socketCalls == 2)) return -1;
    ++openSockets; return 42;
}
int OwnershipClose(int fd)
{
    if (fd == -1) { check(networkMode == 4, "unexpected invalid close"); return -1; }
    check(fd == 42 && openSockets > 0, "unexpected socket close");
    --openSockets; ++closeCalls; return 0;
}
ssize_t OwnershipSendTo(int fd, const void* data, size_t size, int flags, const struct sockaddr*, socklen_t)
{
    check(fd == 42 && !flags && size == sizeof(ECHOREQUEST), "unexpected send");
    auto request = static_cast<const ECHOREQUEST*>(data);
    check(request->icmpHdr.ID == 123 && request->icmpHdr.Seq == sends + 1, "synthetic sequence");
    ++sends;
    if (networkMode == 5) { errno = EIO; return -1; }
    return size;
}
ssize_t OwnershipRecvFrom(int fd, void* data, size_t size, int flags, struct sockaddr*, socklen_t*)
{
    check(fd == 42 && !flags && size == sizeof(ECHOREPLY), "unexpected receive");
    ECHOREPLY reply = {};
    reply.ipHdr.TTL = 64;
    reply.echoRequest.icmpHdr.Type = ICMP_ECHOREPLY;
    reply.echoRequest.icmpHdr.ID = 123;
    reply.echoRequest.icmpHdr.Seq = ++receives;
    std::memcpy(data, &reply, sizeof(reply)); return 64;
}
int OwnershipSelect(int n, fd_set*, fd_set*, fd_set*, struct timeval* timeout)
{ check(n == 43 && timeout->tv_sec == 1, "unexpected select"); return networkMode == 1 ? 0 : 1; }
const char* OwnershipInetNtop(int family, const void*, char* out, socklen_t size)
{
    check(family == AF_INET && size >= 10, "unexpected address format");
    std::strcpy(out, "synthetic"); return out;
}
pid_t OwnershipGetPid() { return 123; }
time_t OwnershipTime(time_t* out) { if (out) *out = 0; return 0; }
AbsoluteTime OwnershipUpTime() { AbsoluteTime value = {}; return value; }
Nanoseconds OwnershipAbsoluteToNanoseconds(AbsoluteTime)
{
    Nanoseconds value = {}; value.lo = ++clockCalls * 1000000; return value;
}

static void pictureCase(const std::string& name, const char* text)
{
    PA_Picture handoff = nullptr, returned = nullptr, param = makePicture();
    {
        CPicture picture;
        if (name == "path") {
            CUTF8String path(reinterpret_cast<const uint8_t*>(text)); picture.fromFileAtPath(&path);
        } else if (name == "bytes") {
            const uint8_t synthetic[] = {1, 2, 3};
            for (int i = 0; i < 20; ++i) picture.setBytes(synthetic, sizeof(synthetic));
        } else if (name == "copy") handoff = picture.createCopy(text);
        else if (name == "gray") handoff = picture.createGrayScale();
        else if (name == "size") {
            unsigned width = 0, height = 0; picture.getSize(&width, &height);
            check(width == 23 && height == 17, "size outputs");
        } else if (name == "thumbnail") handoff = picture.createThumbnail(23, 17);
        else check(false, "unknown picture test");
        if (handoff) check(pictures[handoff] == 1, "handoff is not sole owned reference");
        check(pictures.count(picture.getPicture()), "wrapper died during callback");
        picture.setReturn(reinterpret_cast<sLONG_PTR*>(&returned));
        check(pictures[returned] == 2, "independently retained return");
        BytePtr params[] = {reinterpret_cast<BytePtr>(&param)};
        picture.toParamAtIndex(params, 1);
        check(param == returned && pictures[param] == 3, "independently retained parameter");
    }
    check(pictures.count(returned) && pictures[returned] == 2, "output survives wrapper");
    PA_DisposePicture(returned); PA_DisposePicture(param);
    if (handoff) PA_DisposePicture(handoff);
}

static void failureCase(const std::string& name, const std::string& failure)
{
    CPicture picture;
    PA_Picture original = picture.getPicture();
    failHandle = failure == "handle"; failCommand = failure == "command";
    failConversion = failure == "conversion"; failCreation = failure == "creation";
    bool threw = false;
    unsigned width = 90, height = 91;
    try {
        if (name == "path") { CUTF8String path; picture.fromFileAtPath(&path); }
        else if (name == "copy") PA_DisposePicture(picture.createCopy(""));
        else if (name == "gray") PA_DisposePicture(picture.createGrayScale());
        else if (name == "size") picture.getSize(&width, &height);
        else if (name == "thumbnail") PA_DisposePicture(picture.createThumbnail(23, 17));
        else if (name == "bytes") picture.setBytes(nullptr, 0);
        else check(false, "unknown failure test");
    } catch (const std::runtime_error&) { threw = true; }
    failHandle = failCommand = failConversion = failCreation = false;
    check(threw, "command failure not surfaced");
    check(width == 90 && height == 91, "failure changed size outputs");
    check(picture.getPicture() == original && pictures.count(original), "failure changed wrapper input");
}

static void scalarCase()
{
    auto input = PA_CreateUnistring(const_cast<PA_Unichar*>(expected.c_str()));
    auto result = PA_CreateUnistring(nullptr), output = PA_CreateUnistring(nullptr);
    {
        C_TEXT wrapper;
        BytePtr params[] = {reinterpret_cast<BytePtr>(&input)};
        wrapper.fromParamAtIndex(params, 1);
        auto changed = utf16("changed");
        PA_SetUnistring(&input, const_cast<PA_Unichar*>(changed.c_str()));
        params[0] = reinterpret_cast<BytePtr>(&output);
        wrapper.toParamAtIndex(params, 1);
        auto resultPtr = &result; wrapper.setReturn(reinterpret_cast<sLONG_PTR*>(&resultPtr));
    }
    textEquals(result, expected); textEquals(output, expected);
    PA_DisposeUnistring(&input); PA_DisposeUnistring(&output); PA_DisposeUnistring(&result);
}

static void arrayCase()
{
    auto arr = PA_CreateVariable(eVK_ArrayUnicode);
    PA_ResizeArray(&arr, 4);
    const char* fixtures[] = {"ASCII", "\xe6\x97\xa5", "\xf0\x9f\x98\x80", "", ""};
    for (int i = 0; i <= 4; ++i) {
        auto text = utf16(fixtures[i]); auto owned = PA_CreateUnistring(const_cast<PA_Unichar*>(text.c_str()));
        PA_SetStringInArray(arr, i, &owned);
    }
    BytePtr params[] = {reinterpret_cast<BytePtr>(&arr)};
    ARRAY_TEXT copy; copy.fromParamAtIndex(params, 1);
    auto changed = utf16("replacement");
    auto replacement = PA_CreateUnistring(const_cast<PA_Unichar*>(changed.c_str()));
    PA_SetStringInArray(arr, 0, &replacement);
    for (int repeat = 0; repeat < 20; ++repeat) {
        auto churn = PA_CreateUnistring(const_cast<PA_Unichar*>(changed.c_str())); PA_DisposeUnistring(&churn);
        copy.toParamAtIndex(params, 1);
        for (int i = 0; i <= 4; ++i) textEquals(PA_GetStringInArray(arr, i), utf16(fixtures[i]));
    }
    auto reject = PA_CreateUnistring(const_cast<PA_Unichar*>(changed.c_str()));
    PA_SetStringInArray(arr, -1, &reject); PA_SetStringInArray(arr, 5, &reject);
    auto wrong = PA_CreateVariable(eVK_Longint); PA_SetStringInArray(wrong, 0, &reject);
    auto missing = arr; missing.uValue.fArray.fData = nullptr;
    PA_SetStringInArray(missing, 0, &reject); PA_SetStringInArray(arr, 0, nullptr);
    textEquals(reject, changed); PA_DisposeUnistring(&reject);
    copy.toParamAtIndex(params, 0);
    copy.setSize(2); copy.toParamAtIndex(params, 1);
    copy.setSize(0); copy.toParamAtIndex(params, 1); PA_ClearVariable(&arr);
    arr = PA_CreateVariable(eVK_Undefined);
    copy.appendUTF16String(changed.c_str()); copy.toParamAtIndex(params, 1); PA_ClearVariable(&arr);
}

static void sdkFailureCase()
{
    failHandle = true;
    auto result = PA_ExecuteCommandByID(457, nullptr, 0);
    check(result.fType == 0 && PA_GetLastError() != eER_NoErr, "raw-kind0 command failure");
    check(PA_GetVariableKind(result) == eVK_Unistring, "raw-kind0 normalization");
    failHandle = false;
    auto arr = PA_CreateVariable(eVK_ArrayUnicode);
    auto bytes = PA_GetHandleSize(arr.uValue.fArray.fData);
    failResize = true; PA_ResizeArray(&arr, 7);
    check(arr.uValue.fArray.fNbElements == 7, "SDK failure changes logical count");
    check(PA_GetHandleSize(arr.uValue.fArray.fData) == bytes, "SDK failure preserves physical size");
    failResize = false;
    arr.uValue.fArray.fNbElements = 0; // Restore only the test descriptor for cleanup.
    PA_ClearVariable(&arr);
}

static void pointerCase(bool failure)
{
    C_POINTER wrapper;
    PointerBlock pointer = {}; pointer.fClass = 1;
    BytePtr params[] = {reinterpret_cast<BytePtr>(&pointer)}; wrapper.fromParamAtIndex(params, 1);
    failPointer = failure;
    auto output = PA_CreateVariable(eVK_Undefined);
    bool threw = false;
    try { wrapper.getVariable(&output); } catch (const std::runtime_error&) { threw = true; }
    failPointer = false;
    check(threw == failure, "pointer failure not surfaced");
    if (failure) check(output.fType == eVK_Undefined, "pointer failure mutated destination");
}

static void dispatchCase(int mode)
{
    networkMode = mode;
    auto hostName = PA_CreateUnistring(const_cast<PA_Unichar*>(expected.c_str()));
    auto responses = PA_CreateVariable(eVK_ArrayUnicode);
    PA_long32 count = 2, limit = 1;
    BytePtr params[] = {reinterpret_cast<BytePtr>(&hostName), reinterpret_cast<BytePtr>(&responses),
                       reinterpret_cast<BytePtr>(&count), reinterpret_cast<BytePtr>(&limit)};
    sLONG_PTR result = 0;
    CommandDispatcher(kInitPlugin, &result, params);
    CommandDispatcher(1, &result, params);
    check(openSockets == 0, "unbalanced synthetic sockets");
    check(frees == (mode == 2 ? 0 : 1), "DNS ownership");
    check(responses.uValue.fArray.fNbElements == (mode <= 1 ? 2 : 0), "response count");
    textEquals(PA_GetStringInArray(responses, 0), utf16(""));
    if (mode <= 1) {
        for (int i = 1; i <= 2; ++i) {
            std::string wanted = mode == 1 ? "Request timeout for icmp_seq " + std::to_string(i)
                : "63 bytes from synthetic: icmp_seq=" + std::to_string(i) + " ttl=64 time=1.000 ms";
            textEquals(PA_GetStringInArray(responses, i), utf16(wanted.c_str()));
        }
        check(sends == 2 && receives == (mode == 0 ? 2 : 0), "synthetic packet control counts");
    }
    PA_long32 status = *reinterpret_cast<PA_long32*>(&result);
    check(status == (mode == 2 ? EAI_NONAME : mode == 4 ? -2 : mode == 5 ? EIO : 0), "return status");
    PA_ClearVariable(&responses); PA_DisposeUnistring(&hostName);
}

int main(int argc, char** argv)
{
    @autoreleasepool {
        check(argc >= 2, "test name required"); gCall4D = host;
        nullEmpty = argc >= 4 && std::string(argv[3]) == "null";
        std::string name = argv[1]; const char* text = argc >= 3 ? argv[2] : ""; expected = utf16(text);
        if (name == "arrays") arrayCase();
        else if (name == "scalar") scalarCase();
        else if (name == "sdk-failures") sdkFailureCase();
        else if (name == "pointer" || name == "pointer-failure") pointerCase(name == "pointer-failure");
        else if (name == "command-returns") {
            check(argc == 6, "result kind and command"); resultKind = std::stoi(argv[4]);
            check(resultKind >= 0 && resultKind <= 2, "unsupported result kind"); pictureCase(argv[5], text);
        } else if (name == "dispatch") {
            check(argc == 5, "dispatch mode"); dispatchCase(std::stoi(argv[4]));
        } else if (name.find(':') != std::string::npos)
            failureCase(name.substr(0, name.find(':')), name.substr(name.find(':') + 1));
        else pictureCase(name, text);
        check(strings.empty(), "unbalanced string allocations");
        check(pictures.empty(), "unbalanced picture references"); check(handles.empty(), "unbalanced handles");
        std::cout << "PASS " << name << " strings=0 pictures=0 handles=0"
                  << " objects=n/a collections=n/a commands=" << commandCalls
                  << " sends=" << sends << " receives=" << receives << " closes=" << closeCalls << "\n";
    }
}
