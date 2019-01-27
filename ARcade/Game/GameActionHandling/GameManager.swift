//
//  GameManager.swift
//  ARcade
//
//  Created by Webb, Christopher Jacob on 11/14/18.
//  Copyright © 2018 University of Houston-Clear lake (ARGuys). All rights reserved.
//

import Foundation
import ARKit
import SceneKit

enum GameState{
    case startup
    case ongoing
    case ending
    case ended
}

class GameManager{
    var sceneManager: SceneManager
    var networkManager: NetworkManager
    var sceneViewDelegate: GameViewController?
    var players: [Int: Player]?
    var aliens: [Int: Alien]?
    var targetList: [Int]?
    var alienSpawnTypeList = [Alien.AlienType.shooting,
                              Alien.AlienType.shooting,
                              Alien.AlienType.shooting,
                              Alien.AlienType.shooting,
                              Alien.AlienType.shooting,
                              Alien.AlienType.diving,
                              Alien.AlienType.diving,
                              Alien.AlienType.diving,
                              Alien.AlienType.multiTakedown]
    var city: City?
    var actionQueue: Queue<GameAction>?
    var sessionState: GameState
    var spawnAlienTimer: Timer?
    var alienShotTimer: Timer?
    var actionTimer: Timer?
    let localID: Int
    
    
    static let MAX_ALIENS: Int = 15
    
    init(scene: SCNScene, netManager: NetworkManager) {
        networkManager = netManager
        localID = netManager.playerID
        sessionState = .startup
        
        if networkManager.isHost{
            actionQueue = Queue<GameAction>()
            players = [:]
            targetList = []
        }
        aliens = [:]
        sceneManager = SceneManager(scene: scene)
        sceneManager.manager = self
    }
    
    func startGame(cityNode: SCNNode) {
        sessionState = .ongoing
        city = City(node: cityNode)
        for peer in networkManager.session.connectedPeers{
            players![peer.hash] = Player(playerType: .balanced)
        }
        players![localID] = Player(playerType: .balanced)
        Alien.numOfPlayers = players!.count
        targetList!.append(-1)
        for player in players!.keys{
            targetList!.append(player)
        }
        spawnAlienTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(spawnAlien), userInfo: nil, repeats: true)
        actionTimer = Timer.scheduledTimer(timeInterval: 1.0/60.0, target: self, selector: #selector(executeNextAction), userInfo: nil, repeats: true)
        alienShotTimer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(createAlienShots), userInfo: nil, repeats: true)

    }
    
    func peerGameSetup(map: ARWorldMap, cityAnchor: ARAnchor){
        sessionState = .ongoing
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = .horizontal
        configuration.initialWorldMap = map
        sceneViewDelegate?.sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        sceneViewDelegate?.sceneView.session.add(anchor: cityAnchor)
        print("ARCADE-INFO: World map recieved and set up locally.")
    }
    
    func endGame() {
        sessionState = .ending
        spawnAlienTimer?.invalidate()
        actionTimer?.invalidate()
        alienShotTimer?.invalidate()
        //scoreboard??????
        // if scoreboard send peers score list
        //segue back to main menu after update session
        sessionState = .ended
    }
    
    @objc func createAlienShots(){
        let numberOfShooters: Int
        var alienList: [Int] = []
        for element in aliens!.keys{
            if aliens![element]?.type != Alien.AlienType.diving{
                alienList.append(element)
            }
        }
        if alienList.count > 3 {
            numberOfShooters = Int.random(in: 0...3)
        }
        else{
            numberOfShooters = Int.random(in: 0...alienList.count)
        }
        var shooterList: [Int] = []
        for _ in 0..<numberOfShooters{
            let alienChosen: Int = alienList.randomElement()!
            alienList.remove(at: alienList.firstIndex(of: alienChosen)!)
            shooterList.append(alienChosen)
        }
        for shooter in shooterList{
            let target = targetList!.randomElement()
            let action: GameAction
            if target == -1 {
                action = GameAction(type: .alienShootCity, sourceID: shooter, targetID: target!)
            }
            else{
                action = GameAction(type: .alienShootPlayer, sourceID: shooter, targetID: target!)
            }
            let sceneUpdate = SceneUpdate(alienID: shooter, targetID: target!)
            networkManager.send(object: sceneUpdate)
            actionQueue!.enqueue(act: action)
        }
    }
    
    @objc func spawnAlien() {
        if aliens!.count >= GameManager.MAX_ALIENS {return}
        if let alienType: Alien.AlienType = alienSpawnTypeList.randomElement() {
            let spawnCoordinates: SCNVector3 = getSpawnCoordinates().getVector()
            let alienNode: SCNNode = sceneManager.makeAlien(id: Alien.numOfAliens, type: alienType, at: spawnCoordinates)
            let alien: Alien = AlienFactory.createAlien(type: alienType, node: alienNode)
            aliens![alien.id] = alien
            let sceneUpdate = SceneUpdate(alienID: alien.id, alienType: alien.type, spawnPoint: Coordinate3D(vector: (alien.node?.position)!))
            networkManager.send(object: sceneUpdate)
            let action = sceneManager.getAlienMoveAction(object: alien.node!, to: city!.node!.position, speed: alien.moveSpeed)
            alien.node?.runAction(action, completionHandler: {self.actionQueue!.enqueue(act: GameAction(type: .alienCrashIntoCity, sourceID: alien.id, targetID: 0))})
        }
    }
    
    
    func AlienShootCity(alienID: Int){
        if let alien = aliens![alienID]{
            let alienPostion: SCNVector3 = (alien.node?.position)!
            let cityPostion : SCNVector3 = (city!.node?.position)!
        
            let bullet: SCNNode = sceneManager.creatAlienBullet(spawnPosition: alienPostion)
            let moveAction : SCNAction = sceneManager.getBulletMoveAction(object: bullet, to: cityPostion, speed: 20)
        
            bullet.runAction(moveAction, completionHandler: {bullet.removeFromParentNode()})
        }
    }
    
    func getSpawnCoordinates() -> Coordinate3D {
        let xSign: Int = [-1,1].randomElement()!
        let zSign: Int = [-1,1].randomElement()!
        let xCoordinate: Float = city!.node!.position.x + Float(xSign) * Float.random(in: 2.0...5.0)
        let yCoordinate: Float = city!.node!.position.y + Float.random(in: 0.2...1.0)
        let zCoordinate: Float = city!.node!.position.z + Float(zSign) * Float.random(in: 2.0...5.0)
        return Coordinate3D(x: xCoordinate, y: yCoordinate, z: zCoordinate)
    }
    
    func apply(this update: SceneUpdate) {
        switch update.type {
        case .SpawnAlien:
            let alienNode: SCNNode = sceneManager.makeAlien(id: Alien.numOfAliens, type: update.alienType, at: Coordinate3D(x: update.spawnPointX, y: update.spawnPointY, z: update.spawnPointZ).getVector())
            alienNode.name = "A" + String(update.alienID)
            let alien: Alien = AlienFactory.createAlien(type: update.alienType, node: alienNode)
            aliens![update.alienID] = alien
            let action = sceneManager.getAlienMoveAction(object: alien.node!, to: (city!.node?.position)!, speed: alien.moveSpeed)
            alien.node?.runAction(action)
        case .RemoveAlien:
            guard let alien = aliens![update.alienID] else {return}
            alien.node?.removeFromParentNode()
            aliens![update.alienID] = nil
        case .SpawnPickup:
            print("ARCADE-ERROR: No implementation for spawning pickups.")
        case .BulletShot:
            if(update.targetID == -1){
                AlienShootCity(alienID: update.alienID)
            }
        case .PlayerShot:
            DispatchQueue.main.async {
                if update.targetID == self.localID {
                    self.sceneViewDelegate?.playerHealthBar.progress = update.healthProgress
                }
            }
        case .CityShot:
            DispatchQueue.main.async {
                self.sceneViewDelegate?.cityHealthBar.progress = update.healthProgress
            }
            if update.healthProgress <= 0 {
                endGame()
            }
        case .EndGame:
            endGame()
        }
    }
    
    @objc func executeNextAction() {
        
        guard let action = actionQueue!.dequeue() else {return}
        
        switch action.type {
        case .playerShootAlien:
            guard let alien = aliens![action.targetID] else {return}
            if alien.takeDamage(from: players![action.sourceID]!.damage) == GameActor.lifeState.dead {
                alien.node!.removeFromParentNode()
                aliens![action.targetID] = nil
                let sceneUpdate = SceneUpdate(alienID: action.targetID)
                networkManager.send(object: sceneUpdate)
            }
        case .playerShootMultiTakedown:
            guard let alien = aliens![action.targetID] else {return}
            if alien.takeDamage(fromPlayerNumber: action.sourceID) == GameActor.lifeState.dead {
                alien.node!.removeFromParentNode()
                aliens![action.targetID] = nil
                let sceneUpdate = SceneUpdate(alienID: action.targetID)
                networkManager.send(object: sceneUpdate)
            }
        case .alienShootPlayer:
            guard let player = players![action.targetID] else { return }
            let health = Float(player.getHealth()) / Float(player.getMaxHealth())
            if action.targetID == localID {
                sceneViewDelegate?.playerHealthBar.progress = health
            } else {
                let sceneUpdate = SceneUpdate(healthProgress: health, playerID: action.targetID)
                networkManager.send(object: sceneUpdate)
            }
            if players![action.targetID]!.takeDamage(from : aliens![action.sourceID]!.damage) == GameActor.lifeState.dead {
                print("ARCADE-INFO: Player has died.")
            }
        case .alienShootCity:
            AlienShootCity(alienID: action.sourceID)
            if city!.takeDamage(from: aliens![action.sourceID]!.damage) == GameActor.lifeState.dead {
                endGame()
            }
            let health = Float((city?.getHealth())!) / Float((city?.getMaxHealth())!)
            let sceneUpdate = SceneUpdate(cityHealth: health)
            networkManager.send(object: sceneUpdate)
            sceneViewDelegate?.cityHealthBar.progress = health
        case .alienCrashIntoCity:
            let sceneUpdate = SceneUpdate(alienID: action.sourceID)
            networkManager.send(object: sceneUpdate)
            if city!.takeDamage(from: aliens![action.sourceID]!.damage) == GameActor.lifeState.dead {
                endGame()
            }
            else {
                aliens![action.sourceID]!.node!.removeFromParentNode()
                aliens![action.sourceID] = nil
            }
            let health = Float((city?.getHealth())!) / Float((city?.getMaxHealth())!)
            let sceneUpdate2 = SceneUpdate(cityHealth: health)
            networkManager.send(object: sceneUpdate2)
            sceneViewDelegate?.cityHealthBar.progress = health
        case .pickup:
            // Pick it up
            break
        }
        
    }
    
    func nodeTapped(node: SCNNode) {
        if node.name == "-1" {
            return
        }
        let typeOfNode: Character = node.name!.removeFirst()
        let nodeID: Int = Int(node.name!)!
        node.name = String(typeOfNode)+node.name!
        var gameAction: GameAction?
        if typeOfNode == "A" {
            let typeOfAlien: Alien.AlienType = aliens![nodeID]!.type
            if typeOfAlien == Alien.AlienType.multiTakedown {
                gameAction = GameAction(type: GameAction.ActionTypes.playerShootMultiTakedown, sourceID: localID, targetID: nodeID)
            } else {
                gameAction = GameAction(type: GameAction.ActionTypes.playerShootAlien, sourceID: localID,
                    targetID: nodeID)
            }
        } else if typeOfNode == "P" {
            gameAction = GameAction(type: GameAction.ActionTypes.pickup, sourceID: localID, targetID: nodeID)
        }
        if let gameAction = gameAction {
            if networkManager.isHost {
                actionQueue!.enqueue(act: gameAction)
            } else {
                networkManager.send(object: gameAction)
            }
        }
    }
    
    func spawnCity(x: Float, y: Float, z: Float) -> SCNNode{
        let cityNode = sceneManager.spawnCity(x: x, y: y, z: z)
        sceneManager.add(node: cityNode)
        return cityNode
    }
    
    func removeCity(node: SCNNode){
        sceneManager.remove(node: node)
    }
    
}

