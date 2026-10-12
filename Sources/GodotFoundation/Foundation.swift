//
//  FoundationUUID.swift
//  GodotApplePlugins
//
//  Created by Miguel de Icaza on 12/14/25.
//

@preconcurrency import SwiftGodotRuntime
import Foundation

// Keep the Godot class name without hiding the Foundation module in Swift.
enum FoundationBindings {
    @Godot
    class Foundation: RefCounted, @unchecked Sendable {

        @Callable static func uuid() -> String {
            UUID().uuidString
        }
    }
}
