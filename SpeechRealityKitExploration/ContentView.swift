import SwiftUI
import RealityKit
import Speech
import AVFoundation

struct ContentView: View {
    var body: some View {
        GameView()
    }
}

struct GameView: View {
    @StateObject private var gameManager = GameManager()
    
    var body: some View {
        ZStack {
            RealityViewContainer(gameManager: gameManager)
                .ignoresSafeArea()
            
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Score: \(gameManager.score)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                        
                        Text("Wave: \(gameManager.waveNumber)")
                            .font(.headline)
                            .foregroundColor(.yellow)
                            .shadow(radius: 2)
                        
                        ProgressView(value: gameManager.health, total: 100.0)
                            .progressViewStyle(LinearProgressViewStyle(tint: .red))
                            .frame(width: 200, height: 8)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(4)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
                
                Spacer()
                
                VStack(spacing: 10) {
                    Text("Say: KEPALA, BADAN, or KAKI")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(15)
                    
                    if gameManager.isListening {
                        Image(systemName: "mic.fill")
                            .font(.title)
                            .foregroundColor(.green)
                            .scaleEffect(gameManager.isListening ? 1.2 : 1.0)
                            .animation(.easeInOut(duration: 0.5).repeatForever(), value: gameManager.isListening)
                    }
                }
                .padding(.bottom, 100)
            }
            
            if gameManager.gameOver {
                VStack(spacing: 20) {
                    Text("GAME OVER")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.red)
                    
                    Text("Final Score: \(gameManager.score)")
                        .font(.title2)
                        .foregroundColor(.white)
                    
                    Button("Restart") {
                        gameManager.restartGame()
                    }
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .padding()
                .background(Color.black.opacity(0.8))
                .cornerRadius(20)
            }
        }
        .onAppear {
            gameManager.startGame()
        }
    }
}

struct RealityViewContainer: UIViewRepresentable {
    typealias UIViewType = ARView
    
    let gameManager: GameManager
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        
        setupScene(arView)
        gameManager.arView = arView
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        
    }
    
    private func setupScene(_ arView: ARView) {
        let camera = PerspectiveCamera()
        let cameraAnchor = AnchorEntity(world: SIMD3(0, 1.5, 3))
        cameraAnchor.addChild(camera)
        arView.scene.addAnchor(cameraAnchor)
        
        let directionalLight = DirectionalLight()
        directionalLight.light.intensity = 8000
        directionalLight.orientation = simd_quatf(angle: -.pi/3, axis: SIMD3(1, 1, 0))
        let lightAnchor = AnchorEntity(world: SIMD3(0, 4, 2))
        lightAnchor.addChild(directionalLight)
        arView.scene.addAnchor(lightAnchor)
        
        let ambientLight = Entity()
        ambientLight.components.set(DirectionalLightComponent(
            color: .white,
            intensity: 3000,
            isRealWorldProxy: false
        ))
        let ambientAnchor = AnchorEntity(world: .zero)
        ambientAnchor.addChild(ambientLight)
        arView.scene.addAnchor(ambientAnchor)
        
        let groundMaterial = SimpleMaterial(color: .darkGray, isMetallic: false)
        let groundMesh = MeshResource.generatePlane(width: 15, depth: 15)
        let groundModel = ModelComponent(mesh: groundMesh, materials: [groundMaterial])
        let groundEntity = Entity()
        groundEntity.position = SIMD3(0, 0, 0)
        groundEntity.components.set(groundModel)
        let groundAnchor = AnchorEntity(world: .zero)
        groundAnchor.addChild(groundEntity)
        arView.scene.addAnchor(groundAnchor)
    }
}

class GameManager: ObservableObject {
    @Published var score: Int = 0
    @Published var health: Double = 100.0
    @Published var waveNumber: Int = 1
    @Published var gameOver: Bool = false
    @Published var isListening: Bool = false
    
    var arView: ARView?
    
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var audioPlayer: AVAudioPlayer?
    
    private var zombieSpawnRate: TimeInterval = 4.0
    private var gameTimer: Timer?
    private var zombieCount: Int = 0
    private var maxZombies: Int = 3
    private var activeZombies: [ZombieEntity] = []
    
    init() {
        setupSpeechRecognition()
        setupAudio()
    }
    
    private func setupSpeechRecognition() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "id-ID"))
        
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    self?.startListening()
                default:
                    print("Speech recognition not authorized")
                }
            }
        }
    }
    
    private func setupAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session setup failed")
        }
    }
    
    private func startListening() {
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        
        audioEngine.prepare()
        try? audioEngine.start()
        
        DispatchQueue.main.async {
            self.isListening = true
        }
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            var isFinal = false
            
            if let result = result {
                let command = result.bestTranscription.formattedString
                self?.processVoiceCommand(command)
                isFinal = result.isFinal
            }
            
            if error != nil || isFinal {
                self?.resetSpeechRecognition()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.startListening()
                }
            }
        }
    }
    
    private func resetSpeechRecognition() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        DispatchQueue.main.async {
            self.isListening = false
        }
    }
    
    private var lastCommandTime: Date = Date()
    private let commandCooldown: TimeInterval = 1.0
    
    private func processVoiceCommand(_ command: String) {
        let now = Date()
        guard now.timeIntervalSince(lastCommandTime) >= commandCooldown else { return }
        
        let lowercaseCommand = command.lowercased()
        print(lowercaseCommand)
        
        if lowercaseCommand.contains("kepala") {
            attackZombie(zone: .head)
            lastCommandTime = now
            resetSpeechRecognition()
        } else if lowercaseCommand.contains("badan") {
            attackZombie(zone: .body)
            lastCommandTime = now
            resetSpeechRecognition()
        } else if lowercaseCommand.contains("kaki") {
            attackZombie(zone: .legs)
            lastCommandTime = now
            resetSpeechRecognition()
        }
    }
    
    func startGame() {
        score = 0
        health = 100.0
        waveNumber = 1
        gameOver = false
        zombieSpawnRate = 4.0
        maxZombies = 3
        activeZombies.removeAll()
        
        spawnZombie()
        gameTimer = Timer.scheduledTimer(withTimeInterval: zombieSpawnRate, repeats: true) { _ in
            self.spawnZombie()
        }
    }
    
    func restartGame() {
        guard let arView = arView else { return }
        
        resetSpeechRecognition()
        
        for anchor in arView.scene.anchors {
            if anchor.children.contains(where: { $0 is ZombieEntity }) {
                arView.scene.removeAnchor(anchor)
            }
        }
        
        gameTimer?.invalidate()
        activeZombies.removeAll()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.startGame()
        }
    }
    
    private func spawnZombie() {
        guard let arView = arView, activeZombies.count < maxZombies, !gameOver else { return }
        
        let zombie = ZombieEntity()
        let randomX = Float.random(in: -1.0...1.0)
        let spawnZ: Float = -5.0
        
        let anchor = AnchorEntity(world: SIMD3(randomX, 0, spawnZ))
        anchor.addChild(zombie)
        arView.scene.addAnchor(anchor)
        
        activeZombies.append(zombie)
        
        let endTransform = Transform(translation: SIMD3(0, 0, 3.0))
        zombie.move(to: endTransform, relativeTo: anchor, duration: 5.0)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            if zombie.parent != nil {
                self.zombieReachedPlayer(zombie)
            }
        }
    }
    
    private func zombieReachedPlayer(_ zombie: ZombieEntity) {
        DispatchQueue.main.async {
            self.health = max(0, self.health - 20)
            if self.health <= 0 {
                self.gameOver = true
                self.gameTimer?.invalidate()
            }
        }
        
        removeZombie(zombie)
    }
    
    private func attackZombie(zone: ZombieEntity.HitZone) {
        guard let zombie = findClosestZombie() else { return }
        
        zombie.takeDamage(zone.damage)
        
        showHitEffect(at: zombie.hitZones[zone]?.position ?? SIMD3.zero, in: zombie.parent!, zone: zone)
        playHitSound()
        
        if zombie.health <= 0 {
            zombieDefeated(zombie, killedBy: zone)
        }
        
        updateScore(zone.damage)
    }
    
    private func showHitEffect(at position: SIMD3<Float>, in parent: Entity, zone: ZombieEntity.HitZone) {
        let hitEffect = Entity()
        hitEffect.position = position
        
        let effectColor: UIColor
        switch zone {
        case .head: effectColor = .red
        case .body: effectColor = .orange
        case .legs: effectColor = .yellow
        }
        
        let material = UnlitMaterial(color: effectColor)
        let mesh = MeshResource.generateSphere(radius: 0.1)
        let modelComponent = ModelComponent(mesh: mesh, materials: [material])
        hitEffect.components.set(modelComponent)
        
        parent.addChild(hitEffect)
        
        let endScale = Transform(scale: SIMD3(3.0, 3.0, 3.0))
        hitEffect.move(to: endScale, relativeTo: hitEffect.parent, duration: 0.4)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            hitEffect.removeFromParent()
        }
    }
    
    private func showDamageIndicator(for zone: ZombieEntity.HitZone, at position: SIMD3<Float>) {
        
    }
    
    private func playHitSound() {
        AudioServicesPlaySystemSound(1519)
    }
    
    private func zombieDefeated(_ zombie: ZombieEntity, killedBy zone: ZombieEntity.HitZone) {
        showDeathIndicator(for: zone, at: zombie.position)
        
        let deathTransform = Transform(
            rotation: simd_quatf(angle: .pi/2, axis: SIMD3(1, 0, 0)),
            translation: zombie.position
        )
        
        zombie.move(to: deathTransform, relativeTo: zombie.parent, duration: 1.0)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.removeZombie(zombie)
        }
    }
    
    private func showDeathIndicator(for zone: ZombieEntity.HitZone, at position: SIMD3<Float>) {
        guard let arView = arView else { return }
        
        let deathText = Entity()
        deathText.position = SIMD3(position.x, position.y + 2.5, position.z)
        
        let killText: String
        let killColor: UIColor
        switch zone {
        case .head:
            killText = "HEADSHOT!"
            killColor = .red
        case .body:
            killText = "BODY KILL!"
            killColor = .orange
        case .legs:
            killText = "LEG KILL!"
            killColor = .yellow
        }
        
        let textMesh = MeshResource.generateText(
            killText,
            extrusionDepth: 0.02,
            font: .boldSystemFont(ofSize: 0.15),
            containerFrame: CGRect.zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        
        let textMaterial = UnlitMaterial(color: killColor)
        let textModel = ModelComponent(mesh: textMesh, materials: [textMaterial])
        deathText.components.set(textModel)
        
        if let firstAnchor = arView.scene.anchors.first {
            firstAnchor.addChild(deathText)
        }
        
        let endTransform = Transform(
            scale: SIMD3(1.2, 1.2, 1.2),
            translation: SIMD3(position.x, position.y + 3.0, position.z)
        )
        deathText.move(to: endTransform, relativeTo: deathText.parent, duration: 1.5)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            deathText.removeFromParent()
        }
    }
    
    private func removeZombie(_ zombie: ZombieEntity) {
        if let index = activeZombies.firstIndex(of: zombie) {
            activeZombies.remove(at: index)
        }
        zombie.parent?.removeFromParent()
    }
    
    private func findClosestZombie() -> ZombieEntity? {
        var closestZombie: ZombieEntity?
        var closestDistance: Float = Float.greatestFiniteMagnitude
        
        for zombie in activeZombies {
            let distance = simd_distance(zombie.position, SIMD3(0, 0, 0))
            if distance < closestDistance {
                closestDistance = distance
                closestZombie = zombie
            }
        }
        
        return closestZombie
    }
    
    private func updateScore(_ points: Int) {
        DispatchQueue.main.async {
            self.score += points
        }
        
        if score > 0 && score % 500 == 0 {
            waveNumber += 1
            zombieSpawnRate = max(1.5, zombieSpawnRate - 0.3)
            maxZombies = min(6, maxZombies + 1)
            
            gameTimer?.invalidate()
            gameTimer = Timer.scheduledTimer(withTimeInterval: zombieSpawnRate, repeats: true) { _ in
                self.spawnZombie()
            }
        }
    }
}

class ZombieEntity: Entity, HasModel {
    enum HitZone: String, CaseIterable {
        case head = "head"
        case body = "body"
        case legs = "legs"
        
        var damage: Int {
            switch self {
            case .head: return 100
            case .body: return 50
            case .legs: return 25
            }
        }
    }
    
    var health: Int = 100
    var hitZones: [HitZone: Entity] = [:]
    private var bodyParts: [Entity] = []
    
    required init() {
        super.init()
        setupZombie()
    }
    
    private func setupZombie() {
        createZombieBody()
        createHitZones()
    }
    
    private func createZombieBody() {
        let headMaterial = SimpleMaterial(color: .green, roughness: 0.8, isMetallic: false)
        let bodyMaterial = SimpleMaterial(color: .gray, roughness: 0.8, isMetallic: false)
        let legsMaterial = SimpleMaterial(color: .brown, roughness: 0.8, isMetallic: false)
        
        let headMesh = MeshResource.generateSphere(radius: 0.2)
        let bodyMesh = MeshResource.generateBox(size: SIMD3(0.5, 0.8, 0.3))
        let legsMesh = MeshResource.generateBox(size: SIMD3(0.4, 1.0, 0.2))
        
        let headModel = ModelComponent(mesh: headMesh, materials: [headMaterial])
        let bodyModel = ModelComponent(mesh: bodyMesh, materials: [bodyMaterial])
        let legsModel = ModelComponent(mesh: legsMesh, materials: [legsMaterial])
        
        let headEntity = Entity()
        headEntity.position = SIMD3(0, 2.0, 0)
        headEntity.components.set(headModel)
        
        let bodyEntity = Entity()
        bodyEntity.position = SIMD3(0, 1.2, 0)
        bodyEntity.components.set(bodyModel)
        
        let legsEntity = Entity()
        legsEntity.position = SIMD3(0, 0.5, 0)
        legsEntity.components.set(legsModel)
        
        addChild(headEntity)
        addChild(bodyEntity)
        addChild(legsEntity)
        
        bodyParts = [headEntity, bodyEntity, legsEntity]
    }
    
    private func createHitZones() {
        let headZone = Entity()
        headZone.position = SIMD3(0, 2.0, 0)
        headZone.name = HitZone.head.rawValue
        addChild(headZone)
        hitZones[.head] = headZone
        
        let bodyZone = Entity()
        bodyZone.position = SIMD3(0, 1.2, 0)
        bodyZone.name = HitZone.body.rawValue
        addChild(bodyZone)
        hitZones[.body] = bodyZone
        
        let legsZone = Entity()
        legsZone.position = SIMD3(0, 0.5, 0)
        legsZone.name = HitZone.legs.rawValue
        addChild(legsZone)
        hitZones[.legs] = legsZone
    }
    
    func takeDamage(_ damage: Int) {
        health = max(0, health - damage)
        
        let flashMaterial = UnlitMaterial(color: .red)
        for bodyPart in bodyParts {
            if let modelComponent = bodyPart.components[ModelComponent.self] {
                var newComponent = modelComponent
                newComponent.materials = [flashMaterial]
                bodyPart.components.set(newComponent)
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.resetMaterials()
        }
    }
    
    private func resetMaterials() {
        let materials = [
            SimpleMaterial(color: .green, roughness: 0.8, isMetallic: false),
            SimpleMaterial(color: .gray, roughness: 0.8, isMetallic: false),
            SimpleMaterial(color: .brown, roughness: 0.8, isMetallic: false)
        ]
        
        for (index, bodyPart) in bodyParts.enumerated() {
            if index < materials.count {
                if let modelComponent = bodyPart.components[ModelComponent.self] {
                    var newComponent = modelComponent
                    newComponent.materials = [materials[index]]
                    bodyPart.components.set(newComponent)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
