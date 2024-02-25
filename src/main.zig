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
var keymap: std.AutoHashMap(c_uint, *const fn () void) = undefined;

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
        _ = C.XGrabKey(display, C.XKeysymToKeycode(display, key.keysym), C.Mod4Mask, window, 0, C.GrabModeAsync, C.GrabModeAsync);
    }
    for ([_]u8{ 1, 3 }) |btn| {
        _ = C.XGrabButton(display, btn, C.Mod4Mask, root, 0, C.ButtonPressMask | C.ButtonReleaseMask | C.PointerMotionMask, C.GrabModeAsync, C.GrabModeAsync, 0, 0);
    }
    _ = C.XGrabButton(display, 1, 0, root, 0, C.ButtonPressMask | C.ButtonReleaseMask, C.GrabModeSync, C.GrabModeAsync, 0, 0);
}

// Application state
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
var win_x: i32 = 0;
var win_y: i32 = 0;
var win_w: i32 = 0;
var win_h: i32 = 0;

var screen_w: c_uint = 0;
var screen_h: c_uint = 0;
var center_w: c_uint = 0;
var center_h: c_uint = 0;

var display: *C.Display = undefined;
var root: C.Window = undefined;
var mouse: C.XButtonEvent = undefined;
var window_changes: C.XWindowChanges = undefined;

// Clients are kept in a doubly-linked list
const L = std.DoublyLinkedList(Client);
var list = L{};
var cursor: ?*L.Node = null; // having the cursor be nullable is annoying..

// IMPROVE: Keeping a pointer to previously_focused window as the previs node in the window list
// may or may not be the previously focused one -- because a circular dl list is used.
var previously_focused: ?*L.Node = undefined;

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
    _ = C.XResizeWindow(display, c.data.w, center_w, center_h);
    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, c.data.w, &attributes);

    const sw: c_int = @intCast(screen_w);
    const sh: c_int = @intCast(screen_h);

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

// IMPROVE: node is optional so that we don't have to do focusing logic in other places.
fn focus(node: ?*L.Node) void {
    if (list.len == 0) return;
    if (cursor) |c| _ = C.XSetWindowBorder(display, c.data.w, NORMAL_BORDER_COLOR);

    // IMPROVE: trying to do the most sensible thing here
    const target = node orelse previously_focused orelse list.first.?;
    previously_focused = cursor;

    _ = C.XSetInputFocus(
        display,
        target.data.w,
        C.RevertToParent,
        C.CurrentTime,
    );
    _ = C.XRaiseWindow(display, target.data.w);
    _ = C.XSetWindowBorder(display, target.data.w, FOCUS_BORDER_COLOR);

    cursor = target;
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
    if (node == cursor) cursor = node.prev;
    // IMPROVE: There is no way of determining if a window is still alive so we have to make sure we set
    // previously_focused to null if we destroy it. Another way is to set an error handler to handle
    // BadWindow errors if we ever try to access it.
    if (previously_focused) |pf| {
        if (node.data.w == pf.data.w) previously_focused = null;
    }

    _ = C.XSetInputFocus(
        display,
        root,
        C.RevertToPointerRoot,
        C.CurrentTime,
    );
    _ = C.XDeleteProperty(display, root, C.XInternAtom(display, "_NET_ACTIVE_WINDOW", 0));

    list.remove(node);
    allocator.destroy(node);
    focus(null);
}

// Event handlers
fn onConfigureRequest(e: *C.XConfigureRequestEvent) void {
    window_changes.x = e.x;
    window_changes.y = e.y;
    window_changes.width = e.width;
    window_changes.height = e.height;
    window_changes.border_width = e.border_width;
    window_changes.sibling = e.above;
    window_changes.stack_mode = e.detail;

    _ = C.XConfigureWindow(display, e.window, @intCast(e.value_mask), &window_changes);
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
            // INVESTIGATE: Is this what we want to do?
            const data = [_]c_long{ C.WithdrawnState, C.None };
            // Data Format: Specifies whether the  data should be viewed  as a list
            // of  8-bit,  16-bit,  or  32-bit  quantities.
            const data_format = 32;
            _ = C.XChangeProperty(
                display,
                node.data.w,
                C.XInternAtom(display, "WM_STATE", 0),
                C.XInternAtom(display, "WM_STATE", 0),
                data_format,
                C.PropModeReplace,
                @ptrCast(&data),
                data.len,
            );
        } else {
            unmanage(allocator, node, false);
        }
    }
}

fn onKeyPress(e: *C.XEvent) void {
    if (keymap.get(e.xkey.keycode)) |action| action();
}

fn onNotifyEnter(e: *C.XEvent) void {
    while (C.XCheckTypedEvent(display, C.EnterNotify, e)) {}
}

fn onButtonPress(e: *C.XEvent) void {
    if (e.xbutton.subwindow == 0) return;
    var attributes: C.XWindowAttributes = undefined;
    _ = C.XGetWindowAttributes(display, e.xbutton.subwindow, &attributes);
    win_w = attributes.width;
    win_h = attributes.height;
    win_x = attributes.x;
    win_y = attributes.y;
    mouse = e.xbutton;

    if (winToNode(e.xbutton.subwindow)) |node| if (node != cursor) focus(node);
    _ = C.XAllowEvents(display, C.ReplayPointer, e.xbutton.time);
    _ = C.XSync(display, 0);
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
        win_x + if (button == 1) dx else 0,
        win_y + if (button == 1) dy else 0,
        @max(10, win_w + if (button == 3) dx else 0),
        @max(10, win_h + if (button == 3) dy else 0),
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
    // TODO:
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
        _ = C.XMoveResizeWindow(
            display,
            node.data.w,
            0,
            0,
            screen_w / 2,
            screen_h - 3 * BORDER_WIDTH,
        );
    }
}

fn tileCurrentRight() void {
    if (cursor) |node| {
        _ = C.XMoveResizeWindow(
            display,
            node.data.w,
            @intCast((screen_w / 2) + 2),
            0,
            (screen_w / 2) - (3 * BORDER_WIDTH),
            screen_h - (3 * BORDER_WIDTH),
        );
    }
}

fn tileAll() void {
    if (list.len < 2) return;
    const vert_split_height: c_uint = @intCast((screen_h - 3 * BORDER_WIDTH) / (list.len - 1));

    var i: c_uint = 0;
    var next = list.first;
    while (next) |node| : (next = node.next) {
        if (node.data.w != cursor.?.data.w) {
            _ = C.XMoveResizeWindow(
                display,
                node.data.w,
                0,
                @intCast(i * vert_split_height),
                (screen_w / 2) - 2,
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
            node.data.wx = attributes.x;
            node.data.wy = attributes.y;
            node.data.ww = attributes.width;
            node.data.wh = attributes.height;

            _ = C.XMoveResizeWindow(display, c.w, 0 + BORDER_WIDTH, 0 + BORDER_WIDTH, screen_w - 3 * BORDER_WIDTH, screen_h - 3 * BORDER_WIDTH);
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
    screen_w = @intCast(C.XDisplayWidth(display, screen));
    screen_h = @intCast(C.XDisplayHeight(display, screen));
    center_w = @divTrunc((3 * screen_w), 5);
    center_h = screen_h - 20;

    _ = C.XSetErrorHandler(handleError);
    _ = C.XSelectInput(display, root, C.SubstructureRedirectMask);
    _ = C.XDefineCursor(display, root, C.XCreateFontCursor(display, 68));

    grabInput(root);
    keymap = initKeyMap(allocator) catch @panic("failed to init keymap");

    _ = C.XSync(display, 0);
    while (!shouldQuit and C.XNextEvent(display, &event) == 0) {
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
