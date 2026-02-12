#!/usr/bin/env swift
import Foundation

let defaultHome = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
let runDirectory = URL(fileURLWithPath: defaultHome, isDirectory: true)
    .appendingPathComponent(".config", isDirectory: true)
    .appendingPathComponent("whisp", isDirectory: true)
    .appendingPathComponent("benchmark-runs", isDirectory: true)

let markerName = ".schema-v7"
let markerContent = "7\n"
let fileManager = FileManager.default

func timestamp() -> String {
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: now)
}

func ensureDirectory(_ url: URL) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
}

do {
    if !fileManager.fileExists(atPath: runDirectory.path) {
        try ensureDirectory(runDirectory)
        let marker = runDirectory.appendingPathComponent(markerName)
        try Data(markerContent.utf8).write(to: marker)
        print("benchmark data not found. initialized new schema-v7 directory.")
        exit(0)
    }

    let marker = runDirectory.appendingPathComponent(markerName)
    if fileManager.fileExists(atPath: marker.path) {
        let raw = try String(contentsOf: marker, encoding: .utf8)
        if raw.trimmingCharacters(in: .whitespacesAndNewlines) == markerContent.trimmingCharacters(in: .whitespacesAndNewlines) {
            print("benchmark data is already schema-v7.")
            exit(0)
        }
    }

    let backupPath = runDirectory.appendingPathComponent(
        "migration-backup-\(timestamp())",
        isDirectory: true
    )
    if fileManager.fileExists(atPath: backupPath.path) {
        try fileManager.removeItem(at: backupPath)
    }
    try fileManager.moveItem(at: runDirectory, to: backupPath)
    try ensureDirectory(runDirectory)
    let newMarker = runDirectory.appendingPathComponent(markerName)
    try Data(markerContent.utf8).write(to: newMarker)
    print("benchmark-v7 migration initialized: old data moved to \(backupPath.path)")
} catch {
    print("migration failed: \(error.localizedDescription)")
    exit(1)
}

