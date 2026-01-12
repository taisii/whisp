import { describe, expect, test } from "bun:test";
import { buildShortcutString, formatShortcutDisplay } from "./shortcut";

describe("buildShortcutString", () => {
  test("builds shortcut with command modifier", () => {
    expect(buildShortcutString({ key: "j", metaKey: true })).toBe("Cmd+J");
  });

  test("builds shortcut with multiple modifiers", () => {
    expect(
      buildShortcutString({ key: "k", ctrlKey: true, altKey: true, shiftKey: true }),
    ).toBe("Ctrl+Alt+Shift+K");
  });

  test("normalizes special keys", () => {
    expect(buildShortcutString({ key: " ", altKey: true })).toBe("Alt+Space");
    expect(buildShortcutString({ key: "ArrowUp", shiftKey: true })).toBe("Shift+Up");
  });

  test("accepts function keys", () => {
    expect(buildShortcutString({ key: "F1", ctrlKey: true })).toBe("Ctrl+F1");
    expect(buildShortcutString({ key: "f12", metaKey: true })).toBe("Cmd+F12");
  });

  test("rejects Fn key", () => {
    expect(buildShortcutString({ key: "Fn", metaKey: true })).toBeNull();
  });
});

describe("formatShortcutDisplay", () => {
  test("formats modifiers and keys for display", () => {
    expect(formatShortcutDisplay("Cmd+J")).toBe("⌘ J");
    expect(formatShortcutDisplay("Ctrl+Alt+Shift+F1")).toBe("⌃ ⌥ ⇧ F1");
  });

  test("handles empty shortcut", () => {
    expect(formatShortcutDisplay("")).toBe("-");
  });
});
