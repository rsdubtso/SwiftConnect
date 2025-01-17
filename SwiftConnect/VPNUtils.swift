//
//  VPNUtils.swift
//  SwiftConnect
//
//  Created by Wenyu Zhao on 8/12/2021.
//

import Foundation
import SwiftUI
import Security
import os.log
import OSLog

enum VPNState {
    case stopped, webauth, processing, launched, viewlogs
    
    var description : String {
      switch self {
      case .stopped: return "stopped"
      case .webauth: return "webauth"
      case .processing: return "launching"
      case .launched: return "launched"
      case .viewlogs: return "viewlogs"
      }
    }
}

enum VPNProtocol: String, Equatable, CaseIterable {
    case globalProtect = "gp", anyConnect = "anyconnect"
    
    var id: String {
        return self.rawValue
    }
    
    var name: String {
        switch self {
        case .globalProtect: return "GlobalProtect"
        case .anyConnect: return "AnyConnect"
        }
    }
}

struct Server: Identifiable {
    var serverName:String
    let id:String
}

class VPNController: ObservableObject {
    @Published public var state: VPNState = .stopped
    @Published public var proto: VPNProtocol = .anyConnect
    var credentials: Credentials?

    private var currentLogURL: URL?;
    static var stdinPath = URL(fileURLWithPath: "\(NSTemporaryDirectory())/\(NSUUID().uuidString)");
    static var sudo_pass: String?;
    private var authMgr: AuthManager?;
    private var authReqResp: AuthRequestResp?;
    static let shared = VPNController()

    private var server_cert_hash: String?;
    private var session_token: String?;
    
    func initialize (credentials: Credentials?) {
        self.credentials = credentials
    }

    func start(credentials: Credentials, save: Bool) {
        self.credentials = credentials
        if save {
            credentials.save()
        }
        credentials.load_sudo_password()
        if credentials.samlv2 {
            self.authMgr = AuthManager(credentials: credentials, preAuthCallback: preAuthCallback, authCookieCallback: authCookieCallback, postAuthCallback: postAuthCallback)
            self.authMgr!.pre_auth()
        }
        else {
            self.startvpn() { succ in
            }
        }
    }
    
    public func startvpn(session_token: String? = "", server_cert_hash: String? = "", _ onLaunch: @escaping (_ succ: Bool) -> Void) {
        state = .processing
        
        // Prepare commands
        Logger.vpnProcess.info("[openconnect] start")
        if credentials!.samlv2 {
            ProcessManager.shared.launch(tool: URL(fileURLWithPath: "/usr/bin/sudo"),
                                         arguments: ["-k", "-S", credentials!.bin_path!, "-b", "--protocol=\(proto)", "--pid-file=/var/run/openconnect.pid", "--cookie-on-stdin", "--servercert=\(server_cert_hash!)", "\(credentials!.portal)"],
                input: Data("\(credentials!.sudo_password!)\n\(session_token!)\n".utf8)) { status, output in
                    Logger.vpnProcess.info("[openconnect] completed")
                }
        }
        else {
            ProcessManager.shared.launch(tool: URL(fileURLWithPath: "/usr/bin/sudo"),
                                         arguments: ["-k", "-S", credentials!.bin_path!, "-b", "--protocol=\(proto)", "--pid-file=/var/run/openconnect.pid", "-u", "\(credentials!.username!)", "--passwd-on-stdin", "\(credentials!.portal)"],
                                         input: Data("\(credentials!.sudo_password!)\n\(credentials!.password!)\n".utf8)) { status, output in
                    Logger.vpnProcess.info("[openconnect] completed")
                }
        }
        Logger.vpnProcess.info("[openconnect] launched")
        AppDelegate.shared.pinPopover = false
    }

    public func restartvpn(_ onLaunch: @escaping (_ succ: Bool) -> Void) {
        terminate(forgetAuth: false)
        startvpn(session_token: self.session_token, server_cert_hash: self.server_cert_hash, onLaunch)
    }
    
    public func restart() {
        restartvpn() {succ in}
    }
    
    func preAuthCallback(authResp: AuthRequestResp?) -> Void {
        self.authReqResp = authResp
        if let err = authResp!.auth_error {
            Logger.vpnProcess.error("\(err)")
            return
        }
        state = .webauth
        // Keep the popup window open until web auth is complete or cancelled
        AppDelegate.shared.pinPopover = true
    }
    
    func authCookieCallback(cookie: HTTPCookie?) -> Void {
        guard let uCookie = cookie else {
            Logger.vpnProcess.error("authCookieCallback: Cookie not received!!!")
            return
        }
        state = .processing
        AppDelegate.shared.pinPopover = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AppDelegate.shared.closePopover()
        }
        self.authMgr!.finish_auth(authReqResp: self.authReqResp, cookie: uCookie)
    }
    
    func postAuthCallback(authResp: AuthCompleteResp?) -> Void  {
        guard let session_token = authResp?.session_token else {
            Logger.vpnProcess.error("postAuthCallback: Session cookie not found!!!")
            return
        }
        self.server_cert_hash = authResp?.server_cert_hash
        self.session_token = session_token
        self.startvpn(session_token: self.session_token, server_cert_hash: self.server_cert_hash) { succ in
        }
    }
    
    func terminate(forgetAuth: Bool = true) {
        state = .processing
        if forgetAuth {
            self.server_cert_hash = nil
            self.session_token = nil
        }
        ProcessManager.shared.terminateProcess(credentials: self.credentials)
    }
}

