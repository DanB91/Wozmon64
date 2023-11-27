const w64 = @import("wozmon64");
const WOZ_AND_JOBS = @embedFile("woz-and-jobs.rgb");
const WOZ_AND_JOBS_WIDTH = 465;
const WOZ_AND_JOBS_HEIGHT = WOZ_AND_JOBS.len / (WOZ_AND_JOBS_WIDTH * 3);

export fn entry() linksection(".entry") void {
    const screen_width = w64.SCREEN_PIXEL_WIDTH_PTR.*;
    const screen_height = w64.SCREEN_PIXEL_HEIGHT_PTR.*;
    const stride = w64.FRAME_BUFFER_STRIDE_PTR.*;
    const frame_buffer = w64.FRAME_BUFFER_PTR[0 .. stride * screen_height];
    const x_offset = (screen_width / 2 - WOZ_AND_JOBS_WIDTH / 2);
    const y_offset = (screen_height / 2 - WOZ_AND_JOBS_HEIGHT / 2);

    while (true) {
        for (0..WOZ_AND_JOBS_HEIGHT) |y| {
            for (0..WOZ_AND_JOBS_WIDTH) |x| {
                const pixel = y * 3 * WOZ_AND_JOBS_WIDTH + x * 3;
                const r = WOZ_AND_JOBS[pixel];
                const g = WOZ_AND_JOBS[pixel + 1];
                const b = WOZ_AND_JOBS[pixel + 2];
                frame_buffer[(y + y_offset) * stride + (x + x_offset)] = .{ .colors = .{
                    .r = r,
                    .g = g,
                    .b = b,
                } };
            }
        }
    }
}
