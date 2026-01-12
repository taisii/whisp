type ShortcutInput = {
  key: string;
  metaKey?: boolean;
  ctrlKey?: boolean;
  altKey?: boolean;
  shiftKey?: boolean;
};

const modifierKeys = new Set(["Shift", "Control", "Alt", "Meta"]);

const specialKeyMap: Record<string, string> = {
  " ": "Space",
  Enter: "Enter",
  Tab: "Tab",
  Backspace: "Backspace",
  Delete: "Delete",
  Escape: "Esc",
  ArrowUp: "Up",
  ArrowDown: "Down",
  ArrowLeft: "Left",
  ArrowRight: "Right",
  Home: "Home",
  End: "End",
  PageUp: "PageUp",
  PageDown: "PageDown",
  Insert: "Insert",
};

const isFunctionKey = (key: string) => /^F\d{1,2}$/i.test(key);

const normalizeKey = (key: string): string | null => {
  if (modifierKeys.has(key)) return null;
  if (specialKeyMap[key]) return specialKeyMap[key];
  if (isFunctionKey(key)) return key.toUpperCase();
  if (key.length === 1) return key.toUpperCase();
  return null;
};

export const buildShortcutString = (input: ShortcutInput): string | null => {
  const mainKey = normalizeKey(input.key);
  const modifiers: string[] = [];

  if (input.metaKey) modifiers.push("Cmd");
  if (input.ctrlKey) modifiers.push("Ctrl");
  if (input.altKey) modifiers.push("Alt");
  if (input.shiftKey) modifiers.push("Shift");

  if (!mainKey || modifiers.length === 0) return null;

  return [...modifiers, mainKey].join("+");
};

const displayMap: Record<string, string> = {
  Cmd: "⌘",
  Command: "⌘",
  CmdOrCtrl: "⌘/⌃",
  CommandOrControl: "⌘/⌃",
  Ctrl: "⌃",
  Control: "⌃",
  Alt: "⌥",
  Option: "⌥",
  Shift: "⇧",
};

export const formatShortcutDisplay = (shortcut: string): string => {
  if (!shortcut) return "-";
  const parts = shortcut.split("+").filter(Boolean);
  return parts
    .map((part) => displayMap[part] ?? part.toUpperCase())
    .join(" ");
};
