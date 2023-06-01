//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

const toolbox = @import("toolbox");
export fn kernel_entry() callconv(.C) noreturn {
    toolbox.hang();
}
