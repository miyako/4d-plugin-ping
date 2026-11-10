#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <time.h>

// Included before every production translation unit, including the complete SDK.
@interface OwnershipURL : NSObject
- (id)initWithString:(NSString *)value;
- (NSString *)absoluteString;
@end
@interface OwnershipImage : NSObject
- (id)initWithCGImage:(CGImageRef)image size:(NSSize)size;
- (NSData *)TIFFRepresentation;
@end
CFURLRef OwnershipCreateURL(CFAllocatorRef, CFStringRef, CFURLPathStyle, Boolean);
CFStringRef OwnershipCopyPath(CFURLRef, CFURLPathStyle);
int OwnershipGetAddrInfo(const char*, const char*, const struct addrinfo*, struct addrinfo**);
void OwnershipFreeAddrInfo(struct addrinfo*);
int OwnershipSocket(int, int, int);
int OwnershipClose(int);
ssize_t OwnershipSendTo(int, const void*, size_t, int, const struct sockaddr*, socklen_t);
ssize_t OwnershipRecvFrom(int, void*, size_t, int, struct sockaddr*, socklen_t*);
int OwnershipSelect(int, fd_set*, fd_set*, fd_set*, struct timeval*);
const char* OwnershipInetNtop(int, const void*, char*, socklen_t);
pid_t OwnershipGetPid();
time_t OwnershipTime(time_t*);
AbsoluteTime OwnershipUpTime();
Nanoseconds OwnershipAbsoluteToNanoseconds(AbsoluteTime);

#define NSURL OwnershipURL
#define NSImage OwnershipImage
#define CFURLCreateWithFileSystemPath OwnershipCreateURL
#define CFURLCopyFileSystemPath OwnershipCopyPath
#define getaddrinfo OwnershipGetAddrInfo
#define freeaddrinfo OwnershipFreeAddrInfo
#define socket OwnershipSocket
#define close OwnershipClose
#define sendto OwnershipSendTo
#define recvfrom OwnershipRecvFrom
#define select OwnershipSelect
#define inet_ntop OwnershipInetNtop
#define getpid OwnershipGetPid
#define time OwnershipTime
#define UpTime OwnershipUpTime
#define AbsoluteToNanoseconds OwnershipAbsoluteToNanoseconds
