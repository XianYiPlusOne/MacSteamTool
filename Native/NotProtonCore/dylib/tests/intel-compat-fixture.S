// Synthetic x86 functions. Only these test-owned instructions are instrumented.
.text
.p2align 4
.globl _np_test_oslist
_np_test_oslist:
    pushq %rbp
    movq %rsp, %rbp
    pushq %r12
    movq %rdi, %rax
    movq %rsi, %r12
.globl _np_test_oslist_gate
_np_test_oslist_gate:
    testq %rax, %rax
    setne %al
    movzbl %al, %eax
    popq %r12
    popq %rbp
    retq

.p2align 4
.globl _np_test_redirect
_np_test_redirect:
    pushq %rbp
    movq %rsp, %rbp
    movq %rdi, %rax
.globl _np_test_redirect_gate
_np_test_redirect_gate:
    movl 0x68(%rax), %esi
    testl %esi, %esi
    jne 1f
    movq 0x60(%rax), %rax
    popq %rbp
    retq
1:
    xorl %eax, %eax
    popq %rbp
    retq
