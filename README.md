# EWM

A Window Manager designed specifically for my workflow on an ultrawide monitor.

![Alt Text](gif.gif)

## Why
I find that tiling window managers are terrible on ultrawide monitors,
the main issue being that if you only have a single window on the
screen, say a text editor, then you end up having the bulk of the text
off to the far left. Floating window managers don't have this issue
but most of them fall short (for me) in other aspects.

Instead of writing hundereds of lines in some bespoke configuration
language trying to add missing functionality I figured it would be
easier to just write a window manager that just does the thing.

## Features
- It does what I want
- No configuration
- Floating
- Psuedo Tiling

## Keybinds

| Key         | Action             |
| ----------- | ------------------ |
| Mod4+q 	  | quit               |
| Mod4+f 	  | fullscreen         |
| Mod4+m 	  | center             |
| Mod4+comma  | previous window    |
| Mod4+period | next window        |
| Mod4+h 	  | tile left          |
| Mod4+l 	  | tile right         |
| Mod4+t 	  | tile all           |
| Mod4+s 	  | stack (center) all |

## Building
Requires zig version 0.12.0 or later.
