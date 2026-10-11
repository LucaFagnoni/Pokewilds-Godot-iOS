#!/usr/bin/env python3
"""Patches applied to the libzt build copy by build_libzt_android.sh.

ZeroTier's Phy.hpp and PortMapper.cpp and libzt's VirtualTap.cpp wait on sockets with select(),
whose fd_set stops at descriptor 1024. A game process can hold more open files
than that, and Android aborts the app on the first FD_SET above the limit.
This gives those files a larger bit set under its own names; the select()
system call itself accepts any descriptor the process may open.
(miniupnpc's connecthostport.c still uses FD_SET, only when connect() is
interrupted by a signal.)
"""
import re
import sys

BIG_FD_SET = r'''
// --- PokeWilds: descriptors above FD_SETSIZE (see libzt_patches.py) ---
#ifndef ZT_BIG_FD_MAX
#include <sys/select.h>
#include <string.h>
#define ZT_BIG_FD_MAX 32768
struct zt_big_fd_set { unsigned long bits[ZT_BIG_FD_MAX / (8 * sizeof(unsigned long))]; };
static inline int zt_big_select(int n, zt_big_fd_set *r, zt_big_fd_set *w, zt_big_fd_set *e, struct timeval *t)
{
	return ::select(n, (fd_set *)(void *)r, (fd_set *)(void *)w, (fd_set *)(void *)e, t);
}
static inline bool zt_big_ok(long fd) { return (fd >= 0) && (fd < ZT_BIG_FD_MAX); }
#define ZT_BIG_WORD(fd) ((unsigned long)(fd) / (8 * sizeof(unsigned long)))
#define ZT_BIG_MASK(fd) (1UL << ((unsigned long)(fd) % (8 * sizeof(unsigned long))))
#define ZT_BIG_FD_SET(fd, set) do { if (zt_big_ok((long)(fd))) (set)->bits[ZT_BIG_WORD(fd)] |= ZT_BIG_MASK(fd); } while (0)
#define ZT_BIG_FD_CLR(fd, set) do { if (zt_big_ok((long)(fd))) (set)->bits[ZT_BIG_WORD(fd)] &= ~ZT_BIG_MASK(fd); } while (0)
#define ZT_BIG_FD_ISSET(fd, set) (zt_big_ok((long)(fd)) && (((set)->bits[ZT_BIG_WORD(fd)] & ZT_BIG_MASK(fd)) != 0))
#define ZT_BIG_FD_ZERO(set) memset((set), 0, sizeof(*(set)))
#endif
// --- end PokeWilds ---
'''

def widen(text):
    text = re.sub(r'\bfd_set\b', 'zt_big_fd_set', text)
    return re.sub(r'\bFD_(SET|CLR|ISSET|ZERO)\(', r'ZT_BIG_FD_\1(', text)

def patch(path, anchor, select_from, select_to, calls=1):
    text = open(path).read()
    if 'ZT_BIG_FD_MAX' in text:
        return
    assert text.count(anchor) == 1, path + ': layout changed'
    assert text.count(select_from) == calls, path + ': select call changed'
    text = widen(text).replace(select_from, select_to)
    open(path, 'w').write(text.replace(anchor, BIG_FD_SET + '\n' + anchor, 1))

def patch_jni(path):
    """zts_errno is one global shared by every thread. When another thread
    clears it between a failed call and the JNI wrapper reading it, the wrapper
    returned -0, which Java sees as success (descriptor 0, or zero bytes =
    end of stream). Report "try again" instead; a real error repeats."""
    text = open(path).read()
    old = 'return retval > -1 ? retval : -(zts_errno);'
    if old not in text:
        return
    text = text.replace(old, 'return retval > -1 ? retval : -(zts_errno ? zts_errno : ZTS_EAGAIN);')
    open(path, 'w').write(text)

def patch_tcp_timers(path):
    """lwIP recovers from a lost segment or a closed window on its slow timer.
    libzt runs that at 500 ms, so every recovery freezes the stream for about
    1.5 s. A 25 ms base timer brings that down to roughly 0.15 s."""
    text = open(path).read()
    old = '#define TCP_TMR_INTERVAL                250'
    if old not in text:
        return
    text = text.replace(old, '#define TCP_TMR_INTERVAL                25')
    # One TCP segment per ZeroTier packet. At the stock 2760 bytes every
    # segment is split into fragments on the wire, and losing any fragment
    # loses the whole segment.
    mss = '#define TCP_MSS                         (LWIP_MTU - 40)'
    assert mss in text, 'lwipopts.h TCP_MSS changed'
    open(path, 'w').write(text.replace(mss, '#define TCP_MSS                         1280'))

if __name__ == '__main__':
    root = sys.argv[1]
    patch_tcp_timers(root + '/src/lwipopts.h')
    patch_jni(root + '/src/bindings/java/JavaSockets.cxx')
    patch(root + '/ext/ZeroTierOne/osdep/Phy.hpp', 'namespace ZeroTier {',
          '::select((int)_nfds + 1,', 'zt_big_select((int)_nfds + 1,')
    patch(root + '/src/VirtualTap.cpp', 'namespace ZeroTier {',
          ' select(nfds, &readfds,', ' zt_big_select(nfds, &readfds,')
    patch(root + '/ext/ZeroTierOne/osdep/PortMapper.cpp', 'namespace ZeroTier {',
          'select(FD_SETSIZE, &fds,', 'zt_big_select(natpmp.s + 1, &fds,', calls=2)
    print('libzt patched')
