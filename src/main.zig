const std = @import("std");
const C = @import("c.zig");

const FOCUS_BORDER_COLOR = 0xffd787;
const NORMAL_BORDER_COLOR = 0x333333;
const BORDER_WIDTH = 2;

// Keybinds, currently every key is directly under Mod4Mask but I will probably add
// the ability to specify modifiers.
const keys = [_]Key{
    .{ .keysym = C.XK_q, .action = &quit },
    .{ .keysym = C.XK_f, .action = &winFullscreen },
    .{ .keysym = C.XK_m, .action = &centerCurrent },
    .{ .keysym = C.XK_comma, .action = &winPrev },
    .{ .keysym = C.XK_period, .action = &winNext },
    .{ .keysym = C.XK_h, .action = &tileCurrentLeft },
    .{ .keysym = C.XK_l, .action = &tileCurrentRight },
    .{ .keysym = C.XK_t, .action = &tileAll },
    .{ .keysym = C.XK_s, .action = &stackAll },
};

const Key = struct {
    keysym: C.KeySym,
    action: *const fn () void,
};

// Generate a keymap with key: keysym and value: function pointer,
// this is to avoid having to define keys to grab and then having to add same
// keys to be handled in keypress handling code.
var keyMap: std.AutoHashMap(c_uint, *const fn () void) = undefined;

fn initKeyMap(allocator: std.mem.Allocator) !std.AutoHashMap(c_uint, *const fn () void) {
    var map = std.AutoHashMap(c_uint, *const fn () void).init(allocator);
    errdefer map.deinit();
    inline for (keys) |key| {
        try map.put(C.XKeysymToKeycode(display, key.keysym), key.action);
    }
    return map;
}

fn grabInput(window: C.Window) void {
    _ = C.XUngrabKey(display, C.AnyKey, C.AnyModifier, root);

    for (keys) |key| {
        _ = C.XGrabKey(
            display,
            C.XKeysymToKeycode(display, key.keysym),
            C.Mod4Mask,
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

// Global application state
const Client = struct {
    full: bool,
    wx: c_int,
    wy: c_int,
    ww: c_int,
    wh: c_int,
    w: C.Window,
};

var shouldQuit = false;

// Primarly used to store window attributes when a window is being
// clicked on before we start potentially moving/resizing it.
var winX: i32 = 0;
var winY: i32 = 0;
var winW: i32 = 0;
var winH: i32 = 0;

var screenW: c_uint = 0;
var screenH: c_uint = 0;
var centerW: c_uint = 0;
var centerH: c_uint = 0;

var display: *C.Display = undefined;
var root: C.Window = undefined;
var mouse: C.XButtonEvent = undefined;
var windowChanges: C.XWindowChanges = undefined;

// Clients are kept in a doubly-linked list
const L = std.DoublyLinkedList(Client);
var list = L{};
var cursor: ?*L.Node = null; // having the cursor be nullable is annoying..

fn addClient(allocator: std.mem.Allocator, window: C.Window) !*L.Node {
    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, window, &attributes);

    const client = Client{
        .full = false,
        .wx = attributes.x,
        .wy = attributes.y,
        .ww = attributes.width,
        .wh = attributes.height,
        .w = window,
    };

    var node = try allocator.create(L.Node);

    node.data = client;
    list.append(node);

    return node;
}

fn center(c: *L.Node) void {
    _ = C.XResizeWindow(display, c.data.w, centerW, centerH);
    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, c.data.w, &attributes);

    const sw: c_int = @intCast(screenW);
    const sh: c_int = @intCast(screenH);

    c.data.wx = @divTrunc((sw - attributes.width), 2);
    c.data.wy = @divTrunc((sh - attributes.height), 2);
    c.data.ww = attributes.width;
    c.data.wh = attributes.height;

    _ = C.XMoveWindow(
        display,
        c.data.w,
        c.data.wx,
        c.data.wy,
    );
}

fn focus(node: *L.Node) void {
    if (list.len == 0) return;
    if (cursor) |prev| _ = C.XSetWindowBorder(display, prev.data.w, NORMAL_BORDER_COLOR);

    _ = C.XSetInputFocus(
        display,
        node.data.w,
        C.RevertToParent,
        C.CurrentTime,
    );
    _ = C.XRaiseWindow(display, node.data.w);
    _ = C.XSetWindowBorder(display, node.data.w, FOCUS_BORDER_COLOR);

    cursor = node;
}

// Utils
fn winToNode(w: C.Window) ?*L.Node {
    var next = list.first;
    while (next) |node| : (next = node.next) {
        if (node.data.w == w) return node;
    }
    return null;
}

fn unmanage(allocator: std.mem.Allocator, node: *L.Node, destroyed: bool) void {
    if (!destroyed) {
        _ = C.XGrabServer(display);
        _ = C.XSetErrorHandler(ignoreError);
        _ = C.XSelectInput(display, node.data.w, C.NoEventMask);
        _ = C.XUngrabButton(display, C.AnyButton, C.AnyModifier, node.data.w);
        _ = C.XSync(display, 0);
        _ = C.XSetErrorHandler(handleError);
        _ = C.XUngrabServer(display);
    }
    if (node == cursor) {
        cursor = node.prev;
    }
    list.remove(node);
    allocator.destroy(node);
    _ = C.XSetInputFocus(
        display,
        root,
        C.RevertToPointerRoot,
        C.CurrentTime,
    );
}

// Event handlers
fn onConfigureRequest(e: *C.XConfigureRequestEvent) void {
    windowChanges.x = e.x;
    windowChanges.y = e.y;
    windowChanges.width = e.width;
    windowChanges.height = e.height;
    windowChanges.border_width = e.border_width;
    windowChanges.sibling = e.above;
    windowChanges.stack_mode = e.detail;

    _ = C.XConfigureWindow(display, e.window, @intCast(e.value_mask), &windowChanges);
}

fn onMapRequest(allocator: std.mem.Allocator, event: *C.XEvent) !void {
    const window: C.Window = event.xmaprequest.window;
    _ = C.XSelectInput(display, window, C.StructureNotifyMask | C.EnterWindowMask);

    _ = C.XMapWindow(display, window);
    _ = C.XSetWindowBorderWidth(display, window, BORDER_WIDTH);

    const node = try addClient(allocator, window);
    focus(node);
}

fn onUnmapNotify(allocator: std.mem.Allocator, e: *C.XEvent) void {
    const ev = &e.xunmap;
    if (winToNode(ev.window)) |node| {
        if (ev.send_event == 1) {
            // TODO: handle this
        } else {
            unmanage(allocator, node, false);
        }
    }
}

fn onKeyPress(e: *C.XEvent) void {
    if (keyMap.get(e.xkey.keycode)) |action| action();
}

fn onNotifyEnter(e: *C.XEvent) void {
    while (C.XCheckTypedEvent(display, C.EnterNotify, e)) {}
}

fn updateWindowAttribute(window: C.Window) void {
    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, window, &attributes);
    winW = attributes.width;
    winH = attributes.height;
    winX = attributes.x;
    winY = attributes.y;
}

fn onButtonPress(e: *C.XEvent) void {
    if (e.xbutton.subwindow == 0) return;
    updateWindowAttribute(e.xbutton.subwindow);
    if (winToNode(e.xbutton.subwindow)) |node| focus(node);
    mouse = e.xbutton;
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
        @max(10, winW + if (button == 3) dx else 0),
        @max(10, winH + if (button == 3) dy else 0),
    );
}

fn onNotifyDestroy(allocator: std.mem.Allocator, e: *C.XEvent) void {
    const ev = &e.xdestroywindow;
    if (winToNode(ev.window)) |node| {
        unmanage(allocator, node, true);
    }
}

fn onButtonRelease(_: *C.XEvent) void {
    mouse.subwindow = 0;
}

// Error handlers
fn handleError(_: ?*C.Display, event: [*c]C.XErrorEvent) callconv(.C) c_int {
    const evt: *C.XErrorEvent = @ptrCast(event);

    switch (evt.error_code) {
        C.BadMatch => logError("BadMatch"),
        C.BadWindow => logError("BadWindow"),
        C.BadDrawable => logError("BadDrawable"),
        else => logError("TODO: I should handle this error"),
    }
    return 0;
}

fn ignoreError(_: ?*C.Display, _: [*c]C.XErrorEvent) callconv(.C) c_int {
    return 0;
}

// Logging
fn logError(msg: []const u8) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print("Error: {s}\n", .{msg}) catch return;
}

fn logInfo(msg: []const u8) void {
    const stdInfo = std.io.getStdOut().writer();
    stdInfo.print("INFO: {s}\n", .{msg}) catch return;
}

// Actions. None of these take any arguments and only work on global state and are
// meant to be mapped to keys.
fn quit() void {
    shouldQuit = true;
}

fn winNext() void {
    if (cursor) |c| {
        if (c.next) |next| focus(next) else if (list.first) |first| focus(first);
    }
}

fn winPrev() void {
    if (cursor) |c| {
        if (c.prev) |prev| focus(prev) else if (list.last) |last| focus(last);
    }
}

fn centerCurrent() void {
    if (cursor) |node| center(node);
}

fn tileCurrentLeft() void {
    if (cursor) |node| {
        var attributes: C.XWindowAttributes = undefined;
        _ = C.XGetWindowAttributes(display, node.data.w, &attributes);

        _ = C.XMoveResizeWindow(
            display,
            node.data.w,
            0,
            0,
            screenW / 2,
            screenH,
        );
    }
}

fn tileCurrentRight() void {
    if (cursor) |node| {
        _ = C.XMoveResizeWindow(
            display,
            node.data.w,
            @intCast((screenW / 2) + 2),
            0,
            screenW / 2,
            screenH,
        );
    }
}

fn tileAll() void {
    const vert_split_height: c_uint = @intCast(screenH / (list.len - 1));

    var i: c_uint = 0;
    var next = list.first;
    while (next) |node| : (next = node.next) {
        if (node.data.w != cursor.?.data.w) {
            _ = C.XMoveResizeWindow(
                display,
                node.data.w,
                0,
                @intCast(i * vert_split_height),
                (screenW / 2) - 2,
                vert_split_height,
            );
            i += 1;
        }
    }
    tileCurrentRight();
}

fn stackAll() void {
    var next = list.first;
    while (next) |node| : (next = node.next) center(node);
}

fn winFullscreen() void {
    if (cursor) |node| {
        const c = node.data;
        if (!c.full) {
            var attributes: C.XWindowAttributes = undefined;
            _ = C.XGetWindowAttributes(display, c.w, &attributes);
            _ = C.XMoveResizeWindow(display, c.w, 0, 0, screenW, screenH);
            node.data.full = true;
        } else {
            _ = C.XMoveResizeWindow(display, c.w, c.wx, c.wy, @as(c_uint, @intCast(c.ww)), @as(c_uint, @intCast(c.wh)));
            node.data.full = false;
        }
    }
}

// Main loop
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var event: C.XEvent = undefined;

    display = C.XOpenDisplay(0) orelse std.os.exit(1);

    const screen = C.DefaultScreen(display);
    root = C.RootWindow(display, screen);
    screenW = @intCast(C.XDisplayWidth(display, screen));
    screenH = @intCast(C.XDisplayHeight(display, screen));
    centerW = @divTrunc((4 * screenW), 5);
    centerH = screenH - 40;

    _ = C.XSetErrorHandler(handleError);
    _ = C.XSelectInput(display, root, C.SubstructureRedirectMask);
    _ = C.XDefineCursor(display, root, C.XCreateFontCursor(display, 68));

    grabInput(root);
    keyMap = initKeyMap(allocator) catch @panic("failed to init keymap");

    while (true) {
        if (shouldQuit) break;
        _ = C.XNextEvent(display, &event);

        switch (event.type) {
            C.MapRequest => try onMapRequest(allocator, &event),
            C.UnmapNotify => onUnmapNotify(allocator, &event),
            C.KeyPress => onKeyPress(&event),
            C.ButtonPress => onButtonPress(&event),
            C.ButtonRelease => onButtonRelease(&event),
            C.MotionNotify => onNotifyMotion(&event),
            C.DestroyNotify => onNotifyDestroy(allocator, &event),
            C.ConfigureRequest => onConfigureRequest(@ptrCast(&event)),
            else => continue,
        }
    }

    _ = C.XCloseDisplay(display);
    std.os.exit(0);
}
