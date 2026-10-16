#!/usr/bin/env python3
"""Jumbo first fit: compile ios_jumbo_first_fit from build/ntdll-unix/virtual_ios.c on macOS.

The function reads the task's own VM map (mach_vm_region_recurse, the same call
on macOS and iOS). The test reserves a 1 GB PROT_NONE range, punches holes into
it, and checks that the lowest hole that fits is returned, that a hole too small
is skipped, that the start is 64K-aligned, and that `from` inside a hole works.

Needs python3 and a C compiler (CC, default cc).
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
start = source.index('static uintptr_t ios_jumbo_first_fit( size_t size, uintptr_t from )')
end = source.index('\nstatic void ios_va_occupancy_probe', start)
func = source[start:end]

test = r'''
#include <assert.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
''' + func + r'''
int main(void)
{
    const size_t MB = 1024 * 1024;
    char *r = mmap( NULL, 1024 * MB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0 );
    assert( r != MAP_FAILED );
    uintptr_t base = ((uintptr_t)r + 0xffff) & ~(uintptr_t)0xffff;
    /* a 16 MB hole low in the range, a 64 MB one higher up */
    uintptr_t small = base + 128 * MB, big = base + 512 * MB;
    assert( munmap( (void *)small, 16 * MB ) == 0 );
    assert( munmap( (void *)big, 64 * MB ) == 0 );

    assert( ios_jumbo_first_fit( 8 * MB, base ) == small );          /* lowest hole that fits */
    assert( ios_jumbo_first_fit( 16 * MB, base ) == small );         /* an exact fit */
    assert( ios_jumbo_first_fit( 32 * MB, base ) == big );           /* too small is skipped */
    assert( ios_jumbo_first_fit( 64 * MB, base ) == big );
    assert( ios_jumbo_first_fit( 32 * MB, big + 0x1234 ) == big + 0x10000 );  /* from inside, 64K-aligned */
    uintptr_t beyond = ios_jumbo_first_fit( 96 * MB, base );         /* none in the range: above it, or none */
    assert( beyond == 0 || beyond >= (uintptr_t)r + 1024 * MB );
    assert( (ios_jumbo_first_fit( 8 * MB, base ) & 0xffff) == 0 );
    printf( "PASS: lowest fitting hole, exact fit, small holes skipped, aligned start from inside a hole\n" );
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-first-fit-') as tmp:
    src, exe = Path(tmp) / 'fit.c', Path(tmp) / 'fit'
    src.write_text(test)
    subprocess.run([os.environ.get('CC', 'cc'), '-O1', str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
