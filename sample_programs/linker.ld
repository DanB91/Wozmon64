ENTRY(entry) 
PAGE_SIZE = 8;
SECTIONS {
    . = 0x2300000;
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
        *(.bss*) 
    }

}
