const std = @import("std");
const C = @import("c.zig");

const Client = struct {
    full: bool,
    wx: c_int,
    wy: c_int,
    ww: c_int,
    wh: c_int,
    w: C.Window,
};

const Key = struct {
    code: C.KeyCode,
    mods: ?c_uint,
};

const keys = [_]Key{
    .{ .code = C.XK_q, .mods = C.Mod4Mask },
    .{ .code = C.XK_f, .mods = C.Mod4Mask },
    .{ .code = C.XK_m, .mods = C.Mod4Mask },
    .{ .code = C.XK_comma, .mods = C.Mod4Mask },
    .{ .code = C.XK_period, .mods = C.Mod4Mask },
    .{ .code = C.XK_h, .mods = C.Mod4Mask },
    .{ .code = C.XK_l, .mods = C.Mod4Mask },
    .{ .code = C.XK_t, .mods = C.Mod4Mask },
    .{ .code = C.XK_s, .mods = C.Mod4Mask },
};

var shouldQuit = false;

var winX: i32 = 0;
var winY: i32 = 0;
var winW: i32 = 0;
var winH: i32 = 0;

var screenW: c_int = 0;
var screenH: c_int = 0;

var display: *C.Display = undefined;
var root: C.Window = undefined;
var mouse: C.XButtonEvent = undefined;
var windowChanges: C.XWindowChanges = undefined;

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
    list.append(node);
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
    if (curr.next) |next| winFocus(next);
}

fn winPrev() void {
    if (curr.prev) |prev| winFocus(prev);
}

fn winCenter(c: *L.Node) void {
    _ = C.XResizeWindow(display, c.data.w, 2752, 1400);
    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, c.data.w, &attributes);

    c.data.wx = @divTrunc((screenW - attributes.width), 2);
    c.data.wy = @divTrunc((screenH - attributes.height), 2);
    c.data.ww = attributes.width;
    c.data.wh = attributes.height;

    _ = C.XMoveWindow(
        display,
        c.data.w,
        c.data.wx,
        c.data.wy,
    );
}

fn winTileLeft() void {
    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, curr.data.w, &attributes);

    _ = C.XMoveResizeWindow(display, curr.data.w, 0, 0, @as(c_uint, @intCast(@divTrunc(screenW, 2))), @intCast(screenH));
}

fn winTileRight() void {
    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, curr.data.w, &attributes);

    _ = C.XMoveResizeWindow(
        display,
        curr.data.w,
        @divTrunc(screenW, 2) + 2,
        0,
        @as(c_uint, @intCast(@divTrunc(screenW, 2))),
        @intCast(screenH),
    );
}

fn tileAll() void {
    var attr: C.XWindowAttributes = undefined;

    var next = list.first;
    const count = list.len - 1;
    const h: c_uint = @intCast(1440 / count);

    var i: c_uint = 0;
    while (next) |node| : (next = node.next) {
        if (node.data.w != curr.data.w) {
            _ = C.XGetWindowAttributes(display, node.data.w, &attr);
            _ = C.XMoveResizeWindow(
                display,
                node.data.w,
                0,
                @intCast(i * h),
                @as(c_uint, @intCast(@divTrunc(screenW, 2) - 2)),
                h,
            );
            i += 1;
        }
    }
    winTileRight();
}

fn stackAll() void {
    var next = list.first;
    while (next) |node| : (next = node.next) winCenter(node);
}

fn winFullscreen() void {
    const c = curr.data;

    if (!c.full) {
        var attributes: C.XWindowAttributes = undefined;
        _ = C.XGetWindowAttributes(display, c.w, &attributes);

        _ = C.XMoveResizeWindow(display, c.w, 0, 0, @as(c_uint, @intCast(screenW)), @as(c_uint, @intCast(screenH)));
        curr.data.full = true;
    } else {
        _ = C.XMoveResizeWindow(display, c.w, c.wx, c.wy, @as(c_uint, @intCast(c.ww)), @as(c_uint, @intCast(c.wh)));
        curr.data.full = false;
    }
}

fn onConfigureRequest(e: *C.XConfigureRequestEvent) void {
    windowChanges.x = e.x;
    windowChanges.y = e.y;
    windowChanges.width = e.width;
    windowChanges.height = e.height;
    windowChanges.border_width = e.border_width;
    windowChanges.sibling = e.above;
    windowChanges.stack_mode = e.detail;

    C.XConfigureWindow(display, e.window, e.value_mask, &windowChanges);
}

fn onMapRequest(allocator: std.mem.Allocator, event: *C.XEvent) !void {
    const window: C.Window = event.xmaprequest.window;

    _ = C.XSelectInput(display, window, C.StructureNotifyMask | C.EnterWindowMask);

    _ = C.XMapWindow(display, window);
    _ = C.XRaiseWindow(display, window);
    _ = C.XSetInputFocus(display, window, C.RevertToParent, C.CurrentTime);
    _ = C.XSetWindowBorderWidth(display, window, 4);

    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, window, &attributes);
    winW = attributes.width;
    winH = attributes.height;
    winX = attributes.x;
    winY = attributes.y;

    try addClient(allocator, @constCast(&window));
    winCenter(curr);
    winFocus(curr);
}

fn onKeyPress(e: *C.XKeyEvent) void {
    if (e.keycode == C.XKeysymToKeycode(display, C.XK_q)) {
        shouldQuit = true;
    }
    if (e.keycode == C.XKeysymToKeycode(display, C.XK_m)) {
        winCenter(curr);
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
    if (e.keycode == C.XKeysymToKeycode(display, C.XK_h)) {
        winTileLeft();
    }
    if (e.keycode == C.XKeysymToKeycode(display, C.XK_l)) {
        winTileRight();
    }
    if (e.keycode == C.XKeysymToKeycode(display, C.XK_t)) {
        tileAll();
    }
    if (e.keycode == C.XKeysymToKeycode(display, C.XK_s)) {
        stackAll();
    }
}

fn onNotifyEnter(e: *C.XEvent) void {
    while (C.XCheckTypedEvent(display, C.EnterNotify, e)) {}
}

fn onNotifyMotion(e: *C.XEvent) void {
    if (mouse.subwindow == 0) return;

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
    var next = list.first;
    var found = false;
    while (next) |node| : (next = node.next) {
        if (node.data.w == e.xdestroywindow.window) {
            if (node.prev) |n| winFocus(n);
            list.remove(node);
            found = true;
            break;
        }
    }
    if (!found) {
        @panic("failed to delete node, this shouldn't happen");
    }
}

fn onButtonPress(e: *C.XEvent) void {
    if (e.xbutton.subwindow == 0) return;

    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, e.xbutton.subwindow, &attributes);
    winW = attributes.width;
    winH = attributes.height;
    winX = attributes.x;
    winY = attributes.y;

    _ = C.XSetInputFocus(
        display,
        e.xbutton.subwindow,
        C.RevertToParent,
        C.CurrentTime,
    );

    _ = C.XRaiseWindow(display, e.xbutton.subwindow);
    mouse = e.xbutton;
}

fn onButtonRelease(_: *C.XEvent) void {
    mouse.subwindow = 0;
}

fn grabInput(window: C.Window) void {
    _ = C.XUngrabKey(display, C.AnyKey, C.AnyModifier, root);

    for (keys) |key| {
        _ = C.XGrabKey(
            display,
            C.XKeysymToKeycode(display, key.code),
            key.mods orelse 0,
            window,
            0,
            C.GrabModeAsync,
            C.GrabModeAsync,
        );
    }

    for ([_]u8{ 1, 3 }) |btn| {
        _ = C.XGrabButton(
            display,
            btn,
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
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var event: C.XEvent = undefined;

    display = C.XOpenDisplay(0) orelse std.os.exit(1);

    const screen = C.DefaultScreen(display);
    root = C.RootWindow(display, screen);
    screenW = C.XDisplayWidth(display, screen);
    screenH = C.XDisplayHeight(display, screen);

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
