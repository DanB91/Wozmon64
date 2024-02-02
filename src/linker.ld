/*
    Copyright Daniel Bokser 2023
    See LICENSE file for permissible source code usage
*/
PAGE_SIZE = 2097152;
SECTIONS {
    . = 0xFFFFFFFF80000000;
    .text : {
        KEEP(*(.entry))
        *(.text*)

    }
    .got : ALIGN(PAGE_SIZE) {
        *(.got*)
    }
    .data : ALIGN(PAGE_SIZE) { 
        *(.data*) 
    }
    .rodata : ALIGN(PAGE_SIZE) { 
        *(.rodata*) 
    }
    .bss : ALIGN(PAGE_SIZE) { 
        _bss_start = .;
        *(.bss*) 
        _bss_end = .;
    }
}
