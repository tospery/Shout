import Foundation
import Socket

public class SSH {
    
    public enum AuthMethod {
        case key(Key)
        case password(String)
        case agent
    }
    
    public struct Key {
        
        public enum DecryptionMethod {
            case passphrase(String)
            case agentOrKeyboard
            case none
        }
        
        public let privateKey: String
        public let publicKey: String
        public let decryptionMethod: DecryptionMethod

        var passphrase: String {
            switch decryptionMethod {
            case .passphrase(let passphrase):
                return passphrase
            case .agentOrKeyboard:
                return String(cString: getpass("Enter passphrase for \(privateKey) (empty for no passphrase):"))
            case .none:
                return ""
            }
        }
        
        public init(privateKey: String, publicKey: String? = nil, decryptionMethod: DecryptionMethod = .none) {
            self.privateKey = privateKey
            self.publicKey = publicKey ?? (privateKey + ".pub")
            self.decryptionMethod = decryptionMethod
        }
        
    }
    
    private init() {}
    
    public static func connect(host: String, port: Int32 = 22, username: String, authMethod: AuthMethod, execution: (_ session: Session) throws -> ()) throws {
        let session = try Session(host: host, port: port)
        try session.authenticate(username: username, authMethod: authMethod)
        try execution(session)
    }
    
    public class Session {
        
        public enum Error: Swift.Error {
            case authError
        }
        
        private let sock: Socket
        private let rawSession: RawSession
        
        public init(host: String, port: Int32 = 22) throws {
            self.sock = try Socket.create()
            self.rawSession = try RawSession()
            
            rawSession.blocking = 1
            try sock.connect(to: host, port: port)
            try rawSession.handshake(over: sock)
        }
        
        public func authenticate(username: String, privateKey: String, publicKey: String? = nil, decryptionMethod: Key.DecryptionMethod = .none) throws {
            let key = SSH.Key(privateKey: privateKey, publicKey: publicKey, decryptionMethod: decryptionMethod)
            try authenticate(username: username, authMethod: .key(key))
        }
        
        public func authenticate(username: String, password: String) throws {
            try authenticate(username: username, authMethod: .password(password))
        }
        
        public func authenticateByAgent(username: String) throws {
            try authenticate(username: username, authMethod: .agent)
        }
        
        public func authenticate(username: String, authMethod: SSH.AuthMethod) throws {
            switch authMethod {
            case let .key(key):
                if case .agentOrKeyboard = key.decryptionMethod {
                    do {
                        try authenticate(username: username, authMethod: .agent)
                        break
                    } catch {}
                }
                try rawSession.authenticate(username: username,
                                            privateKey: key.privateKey,
                                            publicKey: key.publicKey,
                                            passphrase: key.passphrase)
            case let .password(password):
                try rawSession.authenticate(username: username, password: password)
            case .agent:
                let agent = try rawSession.agent()
                try agent.connect()
                try agent.listIdentities()
                
                var last: RawAgentPublicKey? = nil
                var success: Bool = false
                while let identity = try agent.getIdentity(last: last) {
                    if agent.authenticate(username: username, key: identity) {
                        success = true
                        break
                    }
                    last = identity
                }
                guard success else {
                    throw Error.authError
                }
            }
        }
        
        public func authenticate(username: String, authMethods: [SSH.AuthMethod]) throws {
            var success = false
            for method in authMethods {
                do {
                    try authenticate(username: username, authMethod: method)
                    success = true
                    break
                } catch {}
            }
            if !success {
                throw Error.authError
            }
        }
        
        @discardableResult
        public func execute(_ command: String, output: ((_ output: String) -> ())? = nil) throws -> Int32 {
            let channel = try rawSession.openChannel()
            try channel.exec(command: command)
            
            while true {
                let (data, bytes) = try channel.readData()
                if bytes == 0 {
                    break
                }
                
                if bytes > 0 {
                    let str = data.withUnsafeBytes { (pointer: UnsafePointer<CChar>) in
                        return String(cString: pointer)
                    }
                    if let output = output {
                        output(str)
                    } else {
                        print(str)
                    }
                } else {
                    throw LibSSH2Error.error(Int32(bytes))
                }
            }
            
            try channel.close()
            try channel.waitClosed()
            
            return channel.exitStatus()
        }
        
        public func capture(_ command: String) throws -> (Int32, String) {
            var ongoing = ""
            let status = try execute(command) { (output) in
                ongoing += output
            }
            return (status, ongoing)
        }
        
    }
    
}
