const std = @import("std");
const C = @import("c.zig");

var shouldQuit = false;

var winX: i32 = 0;
var winY: i32 = 0;
var winW: i32 = 0;
var winH: i32 = 0;

var sw: c_int = 0;
var sh: c_int = 0;

var ww: c_int = 0;
var wh: c_int = 0;

var display: *C.Display = undefined;
var root: C.Window = undefined;
var mouse: C.XButtonEvent = undefined;
var winChanges: *C.XWindowChanges = undefined;

const Client = struct {
    full: bool,
    wx: c_int,
    wy: c_int,
    ww: c_int,
    wh: c_int,
    w: C.Window,
};
const L = std.DoublyLinkedList(Client);

var list = L{};
var curr: *L.Node = undefined;

fn addClient(allocator: std.mem.Allocator, window: *C.Window) !void {
    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, window.*, &attributes);

    const client = Client{
        .full = false,
        .wx = attributes.x,
        .wy = attributes.y,
        .ww = attributes.width,
        .wh = attributes.height,
        .w = window.*,
    };

    var node = try allocator.create(L.Node);
    node.data = client;
    list.prepend(node);
    curr = node;
}

fn winFocus(c: *L.Node) void {
    curr = c;
    _ = C.XSetInputFocus(
        display,
        curr.data.w,
        C.RevertToParent,
        C.CurrentTime,
    );
    _ = C.XRaiseWindow(display, curr.data.w);
}

fn winNext() void {
    if (curr.next) |next| {
        winFocus(next);
    }
}

fn winPrev() void {
    if (curr.prev) |prev| {
        winFocus(prev);
    }
}

fn winDel(w: C.Window) void {
    var next = list.first;

    while (next) |node| : (next = node.next) {
        if (node.data.w == w) {
            list.remove(node);
            break;
        }
    }
}

fn winCenter() void {
    _ = C.XResizeWindow(display, curr.data.w, 2300, 1300);
    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, curr.data.w, &attributes);

    _ = C.XMoveWindow(
        display,
        curr.data.w,
        @divTrunc((sw - attributes.width), 2),
        @divTrunc((sh - attributes.height), 2),
    );
}

fn winFullscreen() void {
    const c = curr.data;

    if (!c.full) {
        var attributes: C.XWindowAttributes = undefined;
        _ = C.XGetWindowAttributes(display, c.w, &attributes);

        _ = C.XMoveResizeWindow(display, c.w, 0, 0, @as(c_uint, @intCast(sw)), @as(c_uint, @intCast(sh)));
        curr.data.full = true;
    } else {
        _ = C.XMoveResizeWindow(display, c.w, c.wx, c.wy, @as(c_uint, @intCast(c.ww)), @as(c_uint, @intCast(c.wh)));
        curr.data.full = false;
    }
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

fn onMapRequest(allocator: std.mem.Allocator, event: *C.XEvent) !void {
    const window: C.Window = event.xmaprequest.window;

    _ = C.XSelectInput(display, window, C.StructureNotifyMask | C.EnterWindowMask);

    _ = C.XMapWindow(display, window);
    _ = C.XRaiseWindow(display, window);
    _ = C.XSetInputFocus(display, window, C.RevertToParent, C.CurrentTime);

    _ = C.XMoveWindow(display, window, 1720, 720);
    _ = C.XResizeWindow(display, window, 1000, 1000);
    _ = C.XSetWindowBorderWidth(display, window, 4);

    // TODO
    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, window, &attributes);
    winW = attributes.width;
    winH = attributes.height;
    winX = attributes.x;
    winY = attributes.y;
    //

    //curr = @constCast(&window);
    try addClient(allocator, @constCast(&window));
    winCenter();
    winFocus(curr);
}

fn onKeyPress(e: *C.XKeyEvent) void {
    if (e.keycode == C.XKeysymToKeycode(display, C.XK_q)) {
        shouldQuit = true;
    }
    if (e.keycode == C.XKeysymToKeycode(display, C.XK_m)) {
        winCenter();
    }
    if (e.keycode == C.XKeysymToKeycode(display, C.XK_comma)) {
        winPrev();
    }
    if (e.keycode == C.XKeysymToKeycode(display, C.XK_period)) {
        winNext();
    }
    if (e.keycode == C.XKeysymToKeycode(display, C.XK_f)) {
        winFullscreen();
    }
}

fn onNotifyEnter(e: *C.XEvent) void {
    while (C.XCheckTypedEvent(display, C.EnterNotify, e)) {}
}

fn onNotifyMotion(e: *C.XEvent) void {
    if (mouse.subwindow == 0) return;

    log("motion") catch unreachable;

    while (C.XCheckTypedEvent(display, C.MotionNotify, e) == @as(c_int, @intCast(1))) {}

    const dx: i32 = @intCast(e.xbutton.x_root - mouse.x_root);
    const dy: i32 = @intCast(e.xbutton.y_root - mouse.y_root);

    const button: i32 = @intCast(mouse.button);

    _ = C.XMoveResizeWindow(
        display,
        mouse.subwindow,
        winX + if (button == 1) dx else 0,
        winY + if (button == 1) dy else 0,
        @max(1, winW + if (button == 3) dx else 0),
        @max(1, winH + if (button == 3) dy else 0),
    );
}

fn onNotifyDestroy(e: *C.XEvent) void {
    winDel(e.xdestroywindow.window);
}

fn onButtonPress(e: *C.XEvent) void {
    if (e.xbutton.subwindow == 0) return;

    //_ = C.XRaiseWindow(display, e.xbutton.subwindow);
    // TODO
    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, e.xbutton.subwindow, &attributes);
    winW = attributes.width;
    winH = attributes.height;
    winX = attributes.x;
    winY = attributes.y;
    //

    _ = C.XSetInputFocus(
        display,
        e.xbutton.subwindow,
        C.RevertToParent,
        C.CurrentTime,
    );

    //winFocus(&e.xbutton.subwindow);
    _ = C.XRaiseWindow(display, e.xbutton.subwindow);
    mouse = e.xbutton;
}

fn onButtonRelease(_: *C.XEvent) void {
    mouse.subwindow = 0;
}

fn grabInput(window: C.Window) void {
    _ = C.XUngrabKey(display, C.AnyKey, C.AnyModifier, root);

    _ = C.XGrabKey(
        display,
        C.XKeysymToKeycode(display, C.XK_q),
        C.Mod4Mask,
        window,
        0,
        C.GrabModeAsync,
        C.GrabModeAsync,
    );

    _ = C.XGrabKey(
        display,
        C.XKeysymToKeycode(display, C.XK_f),
        C.Mod4Mask,
        window,
        0,
        C.GrabModeAsync,
        C.GrabModeAsync,
    );

    _ = C.XGrabKey(
        display,
        C.XKeysymToKeycode(display, C.XK_m),
        C.Mod4Mask,
        window,
        0,
        C.GrabModeAsync,
        C.GrabModeAsync,
    );

    _ = C.XGrabKey(
        display,
        C.XKeysymToKeycode(display, C.XK_comma),
        C.Mod4Mask,
        window,
        0,
        C.GrabModeAsync,
        C.GrabModeAsync,
    );

    _ = C.XGrabKey(
        display,
        C.XKeysymToKeycode(display, C.XK_period),
        C.Mod4Mask,
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

    _ = C.XGrabButton(
        display,
        3,
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

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
            C.MapRequest => try onMapRequest(allocator, &event),
            C.KeyPress => onKeyPress(@ptrCast(&event)),
            C.ButtonPress => onButtonPress(&event),
            C.ButtonRelease => onButtonRelease(&event),
            C.MotionNotify => onNotifyMotion(&event),
            C.DestroyNotify => onNotifyDestroy(&event),
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
