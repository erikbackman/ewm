const std = @import("std");
const C = @import("c.zig");

var shouldQuit = false;

var winX: i32 = 0;
var winY: i32 = 0;
var winW: u32 = 0;
var winH: u32 = 0;

var sw: c_int = 0;
var sh: c_int = 0;

var ww: c_int = 0;
var wh: c_int = 0;

var display: *C.Display = undefined;
var root: C.Window = undefined;
var mouse: C.XButtonEvent = undefined;
var winChanges: *C.XWindowChanges = undefined;

const Client = struct {
    next: *Client,
    prev: *Client,

    focused: bool,
    wx: i32,
    wy: i32,
    ww: u32,
    wh: u32,
    w: C.Window,
};

//*Client = undefined;
var curr: *C.Window = undefined;

fn winFocus(c: *C.Window) void {
    curr = c;
    _ = C.XSetInputFocus(
        display,
        curr.*,
        C.RevertToParent,
        C.CurrentTime,
    );
    _ = C.XRaiseWindow(display, curr.*);
}

fn winCenter(w: C.Window) void {
    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, w, &attributes);

    const x = @divTrunc((sw - attributes.x), 2);
    const y = @divTrunc((sh - attributes.y), 2);

    _ = C.XMoveWindow(display, w, x, y);
}

fn onConfigureRequest(e: *C.XConfigureRequestEvent) void {
    var changes: C.XWindowChanges = undefined;

    changes.x = e.x;
    changes.y = e.y;
    changes.width = e.width;
    changes.height = e.height;
    changes.border_width = e.border_width;
    changes.sibling = e.above;
    changes.stack_mode = e.detail;

    C.XConfigureWindow(display, e.window, e.value_mask, &changes);
}

fn onMapRequest(event: *C.XEvent) void {
    const window: C.Window = event.xmaprequest.window;

    _ = C.XSelectInput(display, window, C.StructureNotifyMask | C.EnterWindowMask);

    _ = C.XMapWindow(display, window);
    _ = C.XRaiseWindow(display, window);
    _ = C.XSetInputFocus(display, window, C.RevertToParent, C.CurrentTime);

    _ = C.XMoveWindow(display, window, 1720, 720);
    _ = C.XResizeWindow(display, window, 1000, 1000);
    _ = C.XSetWindowBorderWidth(display, window, 4);

    curr = @constCast(&window);
    winFocus(@constCast(&window));
}

fn onKeyPress(e: *C.XKeyEvent) void {
    if (e.keycode == C.XKeysymToKeycode(display, C.XK_space)) {
        shouldQuit = true;
    }
    if (e.keycode == C.XKeysymToKeycode(display, C.XK_m)) {
        winCenter(curr.*);
    }
}

fn onNotifyEnter(e: *C.XEvent) void {
    while (C.XCheckTypedEvent(display, C.EnterNotify, e)) {}
}

fn onNotifyMotion(e: *C.XEvent) void {
    if (!mouse.subwindow) return;

    while (C.XCheckTypedEvent(display, C.MotionNotify, e)) {}

    const dx = e.xbutton.x_root - mouse.x_root;
    const dy = e.xbutton.y_root - mouse.y_root;

    C.XMoveResizeWindow(
        display,
        mouse.subwindow,
        winX + if (mouse.button == 1) dx else 0,
        winY + if (mouse.button == 1) dy else 0,
        @max(1, winW + if (mouse.button == 3) dx else 0),
        @max(1, winH + if (mouse.button == 3) dy else 0),
    );
}

fn onButtonPress(e: *C.XEvent) void {
    if (e.xbutton.subwindow == 0) return;

    //_ = C.XRaiseWindow(display, e.xbutton.subwindow);
    winFocus(&e.xbutton.subwindow);
    mouse = e.xbutton;
}

fn onButtonRelease(_: *C.XEvent) void {
    mouse.subwindow = 0;
}

fn grabInput(window: C.Window) void {
    _ = C.XUngrabKey(display, C.AnyKey, C.AnyModifier, root);

    _ = C.XGrabKey(
        display,
        C.XKeysymToKeycode(display, C.XK_space),
        C.ControlMask,
        window,
        0,
        C.GrabModeAsync,
        C.GrabModeAsync,
    );

    _ = C.XGrabKey(
        display,
        C.XKeysymToKeycode(display, C.XK_m),
        C.ControlMask,
        window,
        0,
        C.GrabModeAsync,
        C.GrabModeAsync,
    );

    _ = C.XGrabButton(
        display,
        1,
        C.Mod4Mask,
        root,
        0,
        C.ButtonPressMask | C.ButtonReleaseMask | C.PointerMotionMask,
        C.GrabModeAsync,
        C.GrabModeAsync,
        0,
        0,
    );
}

pub fn main() !void {
    var event: C.XEvent = undefined;

    display = C.XOpenDisplay(0) orelse std.os.exit(1);

    const screen = C.DefaultScreen(display);
    root = C.RootWindow(display, screen);
    sw = C.XDisplayWidth(display, screen);
    sh = C.XDisplayHeight(display, screen);

    _ = C.XSelectInput(display, root, C.SubstructureRedirectMask);
    _ = C.XDefineCursor(display, root, C.XCreateFontCursor(display, 68));

    grabInput(root);

    while (true) {
        if (shouldQuit) break;
        _ = C.XNextEvent(display, &event);

        switch (event.type) {
            C.Expose => continue,
            C.MapRequest => onMapRequest(&event),
            C.KeyPress => onKeyPress(@ptrCast(&event)),
            C.ButtonPress => onButtonPress(&event),
            C.ButtonRelease => onButtonRelease(&event),
            else => continue,
        }
    }
    _ = C.XCloseDisplay(display);
    std.os.exit(0);
}

fn log(msg: []const u8) !void {
    const file = try std.fs.openFileAbsolute("/home/ebn/logs/ewm.log", .{ .mode = .write_only });
    defer file.close();
    _ = try file.write(msg);
}
