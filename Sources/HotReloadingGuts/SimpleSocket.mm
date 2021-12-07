//
//  SimpleSocket.mm
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/SimpleSocket.mm#15 $
//
//  Server and client primitives for networking through sockets
//  more esailly written in Objective-C than Swift. Subclass to
//  implement service or client that runs on a background thread
//  implemented by overriding the "runInBackground" method.
//

#import "SimpleSocket.h"

#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netdb.h>
#import <ifaddrs.h>

#if 0
#define SLog NSLog
#else
#define SLog while(0) NSLog
#endif

@implementation SimpleSocket

+ (int)error:(NSString *)message {
    NSLog(message, strerror(errno));
    return -1;
}

+ (void)startServer:(NSString *)address {
    [self performSelectorInBackground:@selector(runServer:) withObject:address];
}

+ (void)runServer:(NSString *)address {
    struct sockaddr_storage serverAddr;
    [self parseV4Address:address into:&serverAddr];

    int serverSocket = [self newSocket:serverAddr.ss_family];
    if (serverSocket < 0)
        return;

    if (bind(serverSocket, (struct sockaddr *)&serverAddr, serverAddr.ss_len) < 0)
        [self error:@"Could not bind service socket: %s"];
    else if (listen(serverSocket, 5) < 0)
        [self error:@"Service socket would not listen: %s"];
    else
        while (TRUE) {
            struct sockaddr_storage clientAddr;
            socklen_t addrLen = sizeof clientAddr;

            int clientSocket = accept(serverSocket, (struct sockaddr *)&clientAddr, &addrLen);
            if (clientSocket > 0) {
                @autoreleasepool {
                    struct sockaddr_in *v4Addr = (struct sockaddr_in *)&clientAddr;
                    NSLog(@"Connection from %s:%d\n",
                          inet_ntoa(v4Addr->sin_addr), ntohs(v4Addr->sin_port));
                    [[[self alloc] initSocket:clientSocket] run];
                }
            }
            else
                [NSThread sleepForTimeInterval:.5];
        }
}

+ (instancetype)connectTo:(NSString *)address {
    struct sockaddr_storage serverAddr;
    [self parseV4Address:address into:&serverAddr];

    int clientSocket = [self newSocket:serverAddr.ss_family];
    if (clientSocket < 0)
        return nil;

    if (connect(clientSocket, (struct sockaddr *)&serverAddr, serverAddr.ss_len) < 0) {
        [self error:@"Could not connect: %s"];
        return nil;
    }

    return [[self alloc] initSocket:clientSocket];
}

+ (int)newSocket:(sa_family_t)addressFamily {
    int optval = 1, newSocket;
    if ((newSocket = socket(addressFamily, SOCK_STREAM, 0)) < 0)
        [self error:@"Could not open service socket: %s"];
    else if (setsockopt(newSocket, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof optval) < 0)
        [self error:@"Could not set SO_REUSEADDR: %s"];
    else if (setsockopt(newSocket, SOL_SOCKET, SO_NOSIGPIPE, (void *)&optval, sizeof(optval)) < 0)
        [self error:@"Could not set SO_NOSIGPIPE: %s"];
    else if (setsockopt(newSocket, IPPROTO_TCP, TCP_NODELAY, (void *)&optval, sizeof(optval)) < 0)
        [self error:@"Could not set TCP_NODELAY: %s"];
    else if (fcntl(newSocket, F_SETFD, FD_CLOEXEC) < 0)
        [self error:@"Could not set FD_CLOEXEC: %s"];
    else
        return newSocket;
    return -1;
}

/**
 * Available formats
 * @"<host>[:<port>]"
 * where <host> can be NNN.NNN.NNN.NNN or hostname, empty for localhost or * for all interfaces
 * The default port is 80 or a specific number to bind or an empty string to allocate any port
 */
+ (BOOL)parseV4Address:(NSString *)address into:(struct sockaddr_storage *)serverAddr {
    NSArray<NSString *> *parts = [address componentsSeparatedByString:@":"];

    struct sockaddr_in *v4Addr = (struct sockaddr_in *)serverAddr;
    bzero(v4Addr, sizeof *v4Addr);

    v4Addr->sin_family = AF_INET;
    v4Addr->sin_len = sizeof *v4Addr;
    v4Addr->sin_port = htons(parts.count > 1 ? parts[1].intValue : 80);

    const char *host = parts[0].UTF8String;

    if (!host[0])
        v4Addr->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    else if (host[0] == '*')
        v4Addr->sin_addr.s_addr = htonl(INADDR_ANY);
    else if (isdigit(host[0]))
        v4Addr->sin_addr.s_addr = inet_addr(host);
    else if (struct hostent *hp = gethostbyname2(host, v4Addr->sin_family))
        memcpy((void *)&v4Addr->sin_addr, hp->h_addr, hp->h_length);
    else {
        [self error:[NSString stringWithFormat:@"Unable to look up host for %@", address]];
        return FALSE;
    }

    return TRUE;
}

- (instancetype)initSocket:(int)socket {
    if ((self = [super init])) {
        clientSocket = socket;
    }
    return self;
}

// Get IP Address
+ (nullable NSString *)getIPAddress {
    NSString *ret = nil;
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    // retrieve the current interfaces - returns 0 on success
    success = getifaddrs(&interfaces);
    if (success == 0) {
        // Loop through linked list of interfaces
        NSMutableDictionary *addrDic = [NSMutableDictionary dictionary];
        temp_addr = interfaces;
        while(temp_addr != NULL) {
            if(temp_addr->ifa_addr->sa_family == AF_INET) {
                // Check if interface is en0 which is the wifi connection on the iPhone
                NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if([name hasPrefix:@"en"]) {
                    // Get NSString from C String
                    NSString *address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    [addrDic setObject:address ?: @"" forKey:name];
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
        
        NSArray *names = [addrDic.allKeys sortedArrayUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
            return ([[obj1 substringFromIndex:2] integerValue] >
                    [[obj2 substringFromIndex:2] integerValue]) ? NSOrderedDescending : NSOrderedAscending;
        }];
        for (NSString *name in names) {
            if ([self isValidIPAddress:addrDic[name]]) {
                ret = addrDic[name];
                break;
            }
        }
    }
    // Free memory
    freeifaddrs(interfaces);
    return ret;
}

+ (BOOL)isValidIPAddress:(NSString *)address {
    const char *utf8 = [address UTF8String];
    int success;

    struct in_addr dst;
    success = inet_pton(AF_INET, utf8, &dst);
    if (success != 1) {
        struct in6_addr dst6;
        success = inet_pton(AF_INET6, utf8, &dst6);
    }

    return success == 1;
}



- (void)run {
    [self performSelectorInBackground:@selector(runInBackground) withObject:nil];
}

- (void)runInBackground {
    [[self class] error:@"-[Networking run] not implemented in subclass"];
}

- (BOOL)readBytes:(void *)buffer length:(size_t)length cmd:(SEL)cmd {
    size_t rd, ptr = 0;
    while (ptr < length &&
       (rd = read(clientSocket, (char *)buffer+ptr, length-ptr)) > 0)
        ptr += rd;
    if (ptr < length) {
        NSLog(@"[%@ %s:%p length:%lu] error: %lu %s",
              self, sel_getName(cmd), buffer, length, ptr, strerror(errno));
        return FALSE;
    }
    return TRUE;
}

- (int)readInt {
    int32_t anint = ~0;
    if (![self readBytes:&anint length:sizeof anint cmd:_cmd])
        return ~0;
    SLog(@"#%d <- %d", clientSocket, anint);
    return anint;
}

- (NSData *)readData {
    size_t length = [self readInt];
    void *bytes = malloc(length);
    if (!bytes || ![self readBytes:bytes length:length cmd:_cmd])
        return nil;
    return [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
}

- (NSString *)readString {
    NSString *str = [[NSString alloc] initWithData:[self readData]
                                          encoding:NSUTF8StringEncoding];
    SLog(@"#%d <- %d '%@'", clientSocket, (int)str.length, str);
    return str;
}

- (BOOL)writeInt:(int)length {
    SLog(@"#%d %d ->", clientSocket, length);
    return write(clientSocket, &length, sizeof length) == sizeof length;
}

- (BOOL)writeData:(NSData *)data {
    uint32_t length = (uint32_t)data.length;
    SLog(@"#%d [%d] ->", clientSocket, length);
    return [self writeInt:length] &&
        write(clientSocket, data.bytes, length) == length;
}

- (BOOL)writeString:(NSString *)string {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    SLog(@"#%d %d '%@' ->", clientSocket, (int)data.length, string);
    return [self writeData:data];
}

- (BOOL)writeCommand:(int)command withString:(NSString *)string {
    return [self writeInt:command] &&
        (!string || [self writeString:string]);
}

- (void)dealloc {
    close(clientSocket);
}

@end
