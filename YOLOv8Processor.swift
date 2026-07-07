import Accelerate
import AVFoundation
import Combine
import CoreMedia
import CoreML
@preconcurrency import CoreVideo
import Foundation
import Vision

// Box to safely capture pixel buffers in @Sendable closures.
private struct PixelBufferBox: @unchecked Sendable { let buffer: CVPixelBuffer }

// CVPixelBuffer concurrency handled by class-level @unchecked Sendable

// ✅ ADD ObservableObject CONFORMANCE
final class YOLOv8Processor: ObservableObject, @unchecked Sendable {
    private let model: yolov8n_oiv7
    private let classNames: [String]
    private let metalResizer: MetalImageResizer?
    private let processingLock = NSLock()
    private var isProcessing = false
    private var frameCount = 0
    private var detectionHistory: [String: Int] = [:]

    private var trackedDetections: [String: TrackedDetection] = [:]
    private var framesSinceLastCleanup = 0

    // SMART THROTTLING - Prevents freezing while keeping speed

    // YOUR ORIGINAL WORKING THRESHOLDS - The key to good detection!
    private let baseThreshold: Float = 0.20
    private let maxDetectionsPerFrame = 40
    private let iouThreshold: Float = 0.45
    private let duplicateIoUThreshold: Float = 0.90

    // YOUR COMPLETE ORIGINAL LISTS - What made it work so well
    private let priorityHouseholdItems = Set([
        "Mobile phone", "Phone", "Keys", "Key", "Remote control", "Glasses", "Sunglasses",
        "Wallet", "Watch", "Cup", "Mug", "Plate", "Bowl", "Fork", "Knife", "Spoon",
        "Book", "Laptop", "Computer keyboard", "Computer mouse", "Tablet computer",
        "Pen", "Pencil", "Scissors", "Bottle", "Medicine", "Pill", "Backpack", "Handbag",
    ])

    private let contextPairs: [String: Set<String>] = [
        "Plate": ["Fork", "Knife", "Spoon", "Food", "Cup", "Mug", "Bowl", "Napkin"],
        "Laptop": ["Computer mouse", "Computer keyboard", "Mobile phone", "Coffee cup", "Mug", "Pen"],
        "Desk": ["Computer keyboard", "Computer mouse", "Laptop", "Monitor", "Pen", "Pencil", "Book"],
        "Bed": ["Pillow", "Blanket", "Mobile phone", "Lamp", "Book", "Clock"],
        "Sink": ["Toothbrush", "Soap", "Towel", "Faucet", "Cup"],
        "Couch": ["Pillow", "Remote control", "Blanket", "Book", "Mobile phone"],
        "Television": ["Remote control", "Couch", "Coffee table"],
        "Refrigerator": ["Food", "Bottle", "Milk", "Juice"],
        "Stove": ["Pot", "Pan", "Kettle", "Spatula"],
        "Table": ["Chair", "Plate", "Cup", "Fork", "Knife", "Spoon"],
        "Coffee table": ["Remote control", "Cup", "Book", "Magazine"],
        "Kitchen counter": ["Knife", "Cutting board", "Mixer", "Toaster", "Coffee maker"],
    ]

    private let conflictingClasses: [(String, String)] = [
        ("Toilet", "Waste container"),
        ("Toilet", "Bucket"),
        ("Cup", "Mug"),
        ("Mobile phone", "Tablet computer"),
        ("Television", "Computer monitor"),
        ("Couch", "Bed"),
        ("Person", "Mannequin"),
        ("Dog", "Cat"),
        ("Real", "Toy"),
    ]

    // YOUR ORIGINAL CLASS LISTS - Complete for best detection
    private let indoorClasses: Set<String> = [
        "Accordion", "Adhesive tape", "Alarm clock", "Armadillo", "Backpack", "Bagel", "Baked goods", "Balance beam", "Band-aid", "Banjo", "Barrel", "Bathroom accessory", "Bathroom cabinet", "Bathtub", "Beaker", "Bed", "Beer", "Belt", "Bench", "Bicycle helmet", "Bidet", "Billiard table", "Blender", "Book", "Bookcase", "Boot", "Bottle", "Bottle opener", "Bowl", "Bowling equipment", "Box", "Boy", "Brassiere", "Bread", "Briefcase", "Broccoli", "Bust", "Cabinetry", "Cake", "Cake stand", "Calculator", "Camera", "Can opener", "Candle", "Candy", "Cat furniture", "Ceiling fan", "Cello", "Chair", "Cheese", "Chest of drawers", "Chicken", "Chime", "Chisel", "Chopsticks", "Christmas tree", "Clock", "Closet", "Clothing", "Coat", "Cocktail", "Cocktail shaker", "Coconut", "Coffee", "Coffee cup", "Coffee table", "Coffeemaker", "Coin", "Computer keyboard", "Computer monitor", "Computer mouse", "Container", "Convenience store", "Cookie", "Cooking spray", "Corded phone", "Cosmetics", "Couch", "Countertop", "Cream", "Cricket ball", "Crutch", "Cupboard", "Curtain", "Cutting board", "Dagger", "Dairy Product", "Desk", "Dessert", "Diaper", "Dice", "Digital clock", "Dishwasher", "Dog bed", "Doll", "Door", "Door handle", "Doughnut", "Drawer", "Dress", "Drill (Tool)", "Drink", "Drinking straw", "Drum", "Dumbbell", "Earrings", "Egg (Food)", "Envelope", "Eraser", "Face powder", "Facial tissue holder", "Fashion accessory", "Fast food", "Fax", "Fedora", "Filing cabinet", "Fireplace", "Flag", "Flashlight", "Flowerpot", "Flute", "Food", "Food processor", "Football helmet", "Frying pan", "Furniture", "Gas stove", "Girl", "Glasses", "Glove", "Goggles", "Grinder", "Guacamole", "Guitar", "Hair dryer", "Hair spray", "Hamburger", "Hammer", "Hand dryer", "Handbag", "Harmonica", "Harp", "Hat", "Headphones", "Heater", "Home appliance", "Honeycomb", "Horizontal bar", "Hot dog", "Houseplant", "Human arm", "Human beard", "Human body", "Human ear", "Human eye", "Human face", "Human foot", "Human hair", "Human hand", "Human head", "Human leg", "Human mouth", "Human nose", "Humidifier", "Ice cream", "Indoor rower", "Infant bed", "Ipod", "Jacket", "Jacuzzi", "Jeans", "Jug", "Juice", "Kettle", "Kitchen & dining room table", "Kitchen appliance", "Kitchen knife", "Kitchen utensil", "Kitchenware", "Knife", "Ladder", "Ladle", "Lamp", "Lantern", "Laptop", "Lavender (Plant)", "Light bulb", "Light switch", "Lily", "Lipstick", "Loveseat", "Luggage and bags", "Man", "Maracas", "Measuring cup", "Mechanical fan", "Medical equipment", "Microphone", "Microwave oven", "Milk", "Miniskirt", "Mirror", "Mixer", "Mixing bowl", "Mobile phone", "Mouse", "Muffin", "Mug", "Musical instrument", "Musical keyboard", "Nail (Construction)", "Necklace", "Nightstand", "Oboe", "Organ (Musical Instrument)", "Oven", "Paper cutter", "Paper towel", "Pastry", "Pen", "Pencil case", "Pencil sharpener", "Perfume", "Personal care", "Piano", "Picnic basket", "Picture frame", "Pillow", "Pizza cutter", "Plastic bag", "Plate", "Platter", "Plumbing fixture", "Popcorn", "Porch", "Poster", "Power plugs and sockets", "Pressure cooker", "Pretzel", "Printer", "Punching bag", "Racket", "Refrigerator", "Remote control", "Ring binder", "Rose", "Ruler", "Salad", "Salt and pepper shakers", "Sandal", "Sandwich", "Saucer", "Saxophone", "Scale", "Scarf", "Scissors", "Screwdriver", "Sculpture", "Serving tray", "Sewing machine", "Shelf", "Shirt", "Shorts", "Shower", "Sink", "Skirt", "Slow cooker", "Soap dispenser", "Sock", "Sofa bed", "Sombrero", "Spatula", "Spice rack", "Spoon", "Stairs", "Stapler", "Stationary bicycle", "Stethoscope", "Stool", "Studio couch", "Suit", "Suitcase", "Sun hat", "Sunglasses", "Swim cap", "Swimwear", "Table", "Table tennis racket", "Tablet computer", "Tableware", "Tap", "Tea", "Teapot", "Teddy bear", "Telephone", "Television", "Tennis racket", "Tiara", "Tie", "Tin can", "Toaster", "Toilet", "Toilet paper", "Tool", "Toothbrush", "Torch", "Towel", "Toy", "Training bench", "Treadmill", "Tripod", "Trombone", "Trousers", "Trumpet", "Umbrella", "Vase", "Watch", "Whisk", "Whiteboard", "Willow", "Window", "Window blind", "Wine", "Wine glass", "Wine rack", "Wok", "Woman", "Wood-burning stove", "Wrench", "Apple", "Artichoke", "Banana", "Bell pepper", "Cabbage", "Cantaloupe", "Carrot", "Common fig", "Cucumber", "Garden Asparagus", "Grape", "Grapefruit", "Lemon", "Mango", "Orange", "Peach", "Pear", "Pineapple", "Pomegranate", "Potato", "Pumpkin", "Radish", "Strawberry", "Tomato", "Vegetable", "Watermelon", "Winter melon", "Zucchini",
    ]

    private let outdoorClasses: Set<String> = [
        "Aircraft", "Airplane", "Alpaca", "Ambulance", "Animal", "Ant", "Antelope", "Auto part", "Axe", "Ball", "Balloon", "Barge", "Baseball bat", "Baseball glove", "Bat (Animal)", "Bear", "Bee", "Beehive", "Beetle", "Bicycle", "Bicycle wheel", "Billboard", "Binoculars", "Bird", "Blue jay", "Boat", "Bomb", "Bow and arrow", "Brown bear", "Building", "Bull", "Bus", "Butterfly", "Camel", "Cannon", "Canoe", "Car", "Carnivore", "Cart", "Castle", "Caterpillar", "Cattle", "Centipede", "Cheetah", "Crab", "Crocodile", "Crow", "Crown", "Deer", "Dinosaur", "Dog", "Dolphin", "Dragonfly", "Duck", "Eagle", "Falcon", "Fish", "Flower", "Flying disc", "Football", "Fountain", "Fox", "Frog", "Giraffe", "Goat", "Goldfish", "Golf ball", "Golf cart", "Gondola", "Goose", "Hedgehog", "Helicopter", "Hippopotamus", "Horse", "Jaguar (Animal)", "Jellyfish", "Jet ski", "Kangaroo", "Kite", "Koala", "Ladybug", "Land vehicle", "Leopard", "Lighthouse", "Limousine", "Lion", "Lizard", "Lobster", "Lynx", "Mammal", "Marine invertebrates", "Marine mammal", "Missile", "Monkey", "Moths and butterflies", "Motorcycle", "Mule", "Mushroom", "Ostrich", "Otter", "Owl", "Oyster", "Paddle", "Palm tree", "Panda", "Parachute", "Parking meter", "Parrot", "Penguin", "Person", "Pig", "Porcupine", "Rabbit", "Raccoon", "Raven", "Rays and skates", "Red panda", "Reptile", "Rhinoceros", "Rocket", "Roller skates", "Rugby ball", "Scorpion", "Sea lion", "Sea turtle", "Seafood", "Seahorse", "Segway", "Shark", "Sheep", "Shellfish", "Shotgun", "Shrimp", "Skateboard", "Ski", "Skull", "Skunk", "Snail", "Snake", "Snowboard", "Snowman", "Snowmobile", "Snowplow", "Sparrow", "Spider", "Sports equipment", "Sports uniform", "Squash (Plant)", "Squid", "Squirrel", "Starfish", "Stop sign", "Street light", "Stretcher", "Submarine", "Submarine sandwich", "Surfboard", "Sushi", "Swan", "Swimming pool", "Sword", "Syringe", "Tank", "Taco", "Taxi", "Tennis ball", "Tent", "Tick", "Tiger", "Tire", "Tortoise", "Tower", "Traffic light", "Traffic sign", "Train", "Tree", "Tree house", "Truck", "Turkey", "Turtle", "Unicycle", "Van", "Vehicle", "Vehicle registration plate", "Violin", "Volleyball (Ball)", "Waffle", "Waffle iron", "Wall clock", "Wardrobe", "Washing machine", "Waste container", "Watercraft", "Weapon", "Whale", "Wheel", "Wheelchair", "Worm", "Woodpecker", "Zebra",
    ]

    private let bothClasses: Set<String> = [
        "Beer", "Bell pepper", "Blue jay", "Book", "Bottle", "Bowl", "Boy", "Bread", "Broccoli", "Butterfly", "Cabbage", "Cantaloupe", "Carrot", "Cat", "Christmas tree", "Clothing", "Coat", "Cocktail", "Coconut", "Coffee", "Coin", "Common fig", "Common sunflower", "Computer mouse", "Cookie", "Cream", "Crocodile", "Croissant", "Cucumber", "Cupboard", "Curtain", "Cutting board", "Deer", "Dessert", "Digital clock", "Dog", "Door", "Drink", "Drum", "Duck", "Earrings", "Egg (Food)", "Elephant", "Envelope", "Eraser", "Face powder", "Fashion accessory", "Fast food", "Flag", "Flashlight", "Flower", "Flute", "Food", "Football", "Footwear", "Fork", "French fries", "French horn", "Frog", "Fruit", "Frying pan", "Garden Asparagus", "Giraffe", "Girl", "Glasses", "Glove", "Goggles", "Goat", "Grape", "Grapefruit", "Guacamole", "Guitar", "Hair dryer", "Hair spray", "Hamburger", "Hammer", "Hamster", "Hand dryer", "Handbag", "Hat", "Headphones", "Heater", "Honeycomb", "Horse", "Hot dog", "Human arm", "Human beard", "Human body", "Human ear", "Human eye", "Human face", "Human foot", "Human hair", "Human hand", "Human head", "Human leg", "Human mouth", "Human nose", "Ice cream", "Insect", "Invertebrate", "Jacket", "Jeans", "Juice", "Kangaroo", "Kitchen utensil", "Kite", "Knife", "Koala", "Ladybug", "Lemon", "Leopard", "Lily", "Lion", "Lizard", "Lobster", "Lynx", "Magpie", "Mammal", "Man", "Maple", "Maracas", "Measuring cup", "Mechanical fan", "Microphone", "Milk", "Miniskirt", "Mirror", "Mixer", "Mixing bowl", "Mobile phone", "Monkey", "Moths and butterflies", "Mouse", "Muffin", "Mug", "Mule", "Mushroom", "Musical instrument", "Musical keyboard", "Nail (Construction)", "Necklace", "Nightstand", "Oboe", "Office supplies", "Orange", "Organ (Musical Instrument)", "Ostrich", "Otter", "Owl", "Oyster", "Paddle", "Palm tree", "Pancake", "Panda", "Paper cutter", "Paper towel", "Parrot", "Pasta", "Pastry", "Peach", "Pear", "Pen", "Pencil case", "Pencil sharpener", "Penguin", "Perfume", "Person", "Personal care", "Personal flotation device", "Piano", "Picnic basket", "Picture frame", "Pig", "Pillow", "Pineapple", "Pitcher (Container)", "Pizza", "Plant", "Plastic bag", "Plate", "Platter", "Plumbing fixture", "Polar bear", "Pomegranate", "Popcorn", "Porch", "Porcupine", "Poster", "Potato", "Power plugs and sockets", "Pressure cooker", "Pretzel", "Printer", "Pumpkin", "Punching bag", "Rabbit", "Raccoon", "Racket", "Radish", "Ratchet (Device)", "Raven", "Rays and skates", "Red panda", "Refrigerator", "Remote control", "Reptile", "Rhinoceros", "Rifle", "Ring binder", "Rocket", "Roller skates", "Rose", "Rugby ball", "Ruler", "Salad", "Salt and pepper shakers", "Sandal", "Sandwich", "Saucer", "Saxophone", "Scale", "Scarf", "Scissors", "Scoreboard", "Screwdriver", "Sculpture", "Serving tray", "Sewing machine", "Shark", "Sheep", "Shelf", "Shellfish", "Shirt", "Shorts", "Shower", "Shrimp", "Sink", "Skateboard", "Ski", "Skirt", "Skull", "Skunk", "Slow cooker", "Snack", "Snail", "Snake", "Snowboard", "Snowman", "Snowmobile", "Snowplow", "Sparrow", "Spatula", "Spice rack", "Spider", "Spoon", "Sports equipment", "Sports uniform", "Squash (Plant)", "Squid", "Squirrel", "Starfish", "Stationary bicycle", "Stethoscope", "Stool", "Stop sign", "Strawberry", "Street light", "Stretcher", "Studio couch", "Submarine", "Submarine sandwich", "Suit", "Suitcase", "Sun hat", "Sunglasses", "Surfboard", "Sushi", "Swan", "Swim cap", "Swimming pool", "Swimwear", "Sword", "Syringe", "Table", "Table tennis racket", "Tablet computer", "Tableware", "Taco", "Tank", "Tap", "Tart", "Taxi", "Tea", "Teapot", "Teddy bear", "Telephone", "Television", "Tennis ball", "Tennis racket", "Tent", "Tiara", "Tick", "Tie", "Tiger", "Tin can", "Tire", "Toaster", "Toilet", "Toilet paper", "Tomato", "Tool", "Toothbrush", "Torch", "Tortoise", "Towel", "Tower", "Toy", "Traffic light", "Traffic sign", "Train", "Training bench", "Treadmill", "Tree", "Tree house", "Tripod", "Trombone", "Trousers", "Truck", "Trumpet", "Turkey", "Turtle", "Umbrella", "Unicycle", "Van", "Vase", "Vegetable", "Vehicle", "Vehicle registration plate", "Violin", "Volleyball (Ball)", "Waffle", "Waffle iron", "Wall clock", "Wardrobe", "Washing machine", "Waste container", "Watch", "Watercraft", "Watermelon", "Weapon", "Whale", "Wheel", "Wheelchair", "Whisk", "Whiteboard", "Willow", "Window", "Window blind", "Wine", "Wine glass", "Wine rack", "Winter melon", "Wok", "Woman", "Wood-burning stove", "Woodpecker", "Worm", "Wrench", "Zebra", "Zucchini",
    ]

    private struct TrackedDetection {
        let id: UUID
        var lastSeen: Int
        var confidence: Float
        var rect: CGRect
        var className: String

        init(detection: YOLODetection, frame: Int) {
            id = detection.id
            lastSeen = frame
            confidence = detection.score
            rect = detection.rect
            className = detection.className
        }
    }

    init(targetSide _: Int = 640) throws {
        metalResizer = MetalImageResizer()

        let config = MLModelConfiguration()
        if #available(iOS 16.0, *) {
            // Workaround: On iOS 17.3, avoid Neural Engine due to known bug
            if #available(iOS 17.3, *), !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 17, minorVersion: 4, patchVersion: 0)) {
                config.computeUnits = .cpuAndGPU
            } else {
                config.computeUnits = .cpuAndNeuralEngine
            }
        } else {
            config.computeUnits = .all
        }

        model = try yolov8n_oiv7(configuration: config)
        classNames = Self.loadClassNames() ?? Self.generateDefaultClassNames()

        // Warm up the model - essential for good performance
        if let dummy = YOLOv8Processor.createDummyPixelBuffer() {
            autoreleasepool {
                _ = try? model.prediction(image: dummy)
            }
        }
    }

    func configureTargetSide(_ side: Int) {
        print("🎯 Target side set to \(side) (using fixed 640x640)")
    }

    // YOUR ORIGINAL FAST PREDICT METHOD with Smart Throttling
    nonisolated func predict(
        image: CVPixelBuffer,
        isPortrait: Bool,
        filterMode: String = "all",
        confidenceThreshold: Float = 0.5,
        completion: @escaping @Sendable ([YOLODetection]?) -> Void
    ) {
        autoreleasepool {
            // Simple processing check
            processingLock.lock()
            if isProcessing {
                processingLock.unlock()
                completion(nil) // skipped, not "nothing detected" — keep last boxes
                return
            }
            isProcessing = true
            processingLock.unlock()

            frameCount += 1

            let adjustedConfidence = max(0.04, confidenceThreshold)

            let px = PixelBufferBox(buffer: image)

            DispatchQueue.global(qos: .userInitiated).async { [weak self, px, isPortrait, filterMode, adjustedConfidence, completion] in
                autoreleasepool {
                    defer {
                        self?.processingLock.lock()
                        self?.isProcessing = false
                        self?.processingLock.unlock()
                    }

                    guard let self else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }

                    // Simple periodic reset only
                    if self.frameCount % 500 == 0 {
                        self.performPeriodicReset()
                    }

                    let imageWidth = CVPixelBufferGetWidth(px.buffer)
                    let imageHeight = CVPixelBufferGetHeight(px.buffer)

                    guard imageWidth > 100, imageHeight > 100 else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }

                    guard let resized = self.metalResizer?.resize(px.buffer, isPortrait: isPortrait) else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    let finalBuffer = resized.buffer
                    let letterboxInfo = resized.info

                    defer {
                        CVPixelBufferUnlockBaseAddress(finalBuffer, .readOnly)
                    }

                    guard let output = try? self.model.prediction(image: finalBuffer),
                          let feature = output.featureValue(for: "var_914"),
                          let rawOutput = feature.multiArrayValue
                    else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }

                    let detections = self.decodeOutput(
                        rawOutput,
                        originalWidth: imageWidth,
                        originalHeight: imageHeight,
                        letterboxInfo: letterboxInfo,
                        filterMode: filterMode,
                        confidenceThreshold: adjustedConfidence
                    )

                    DispatchQueue.main.async {
                        completion(detections)
                    }
                }
            }
        }
    }

    // YOUR ORIGINAL LETTERBOX METHOD
    // YOUR ORIGINAL DECODE METHOD - The heart of good detection!
    private func decodeOutput(
        _ rawOutput: MLMultiArray,
        originalWidth: Int,
        originalHeight: Int,
        letterboxInfo: LetterboxInfo,
        filterMode: String,
        confidenceThreshold: Float
    ) -> [YOLODetection] {
        let numAnchors = 8400
        let numClasses = 601
        var detections: [YOLODetection] = []
        var contextObjects: [String] = []

        let dataPointer = rawOutput.dataPointer.assumingMemoryBound(to: Float.self)
        let scale = letterboxInfo.scale
        let padX = letterboxInfo.padX
        let padY = letterboxInfo.padY
        let wasRotated = letterboxInfo.wasRotated

        var detectionCount = 0
        let maxRawDetections = 150

        // ── Accelerate: pre-compute best class + score per anchor ──
        let classStartPtr = dataPointer + 4 * numAnchors
        var bestClasses = [Int](repeating: 0, count: numAnchors)
        var maxScoresAll = [Float](repeating: 0, count: numAnchors)

        for i in 0 ..< numAnchors {
            var maxVal: Float = 0
            var maxIdx: vDSP_Length = 0
            vDSP_maxvi(classStartPtr + i, vDSP_Stride(numAnchors), &maxVal, &maxIdx, vDSP_Length(numClasses))
            maxScoresAll[i] = maxVal
            bestClasses[i] = Int(maxIdx) / numAnchors
        }

        // FIRST PASS: Find context objects (using pre-computed scores)
        for i in 0 ..< numAnchors {
            let x_center = dataPointer[i]
            let y_center = dataPointer[numAnchors + i]

            if x_center < Float(padX) || x_center > Float(640 - padX) ||
                y_center < Float(padY) || y_center > Float(640 - padY)
            {
                continue
            }

            if maxScoresAll[i] > 0.5 {
                let bestClass = bestClasses[i]
                let className = bestClass < classNames.count ? classNames[bestClass] : "Unknown"
                if contextPairs.keys.contains(className) {
                    contextObjects.append(className)
                }
            }
        }

        // SECOND PASS: Main detection with pre-computed scores
        for i in 0 ..< numAnchors {
            if detectionCount > maxRawDetections { break }

            let x_center = dataPointer[i]
            let y_center = dataPointer[numAnchors + i]
            let box_width = dataPointer[2 * numAnchors + i]
            let box_height = dataPointer[3 * numAnchors + i]

            if x_center < Float(padX) || x_center > Float(640 - padX) ||
                y_center < Float(padY) || y_center > Float(640 - padY)
            {
                continue
            }

            let maxScore = maxScoresAll[i]
            let bestClass = bestClasses[i]

            let className = bestClass < classNames.count ? classNames[bestClass] : "Unknown"

            // YOUR ORIGINAL DYNAMIC THRESHOLD CALCULATION
            var threshold = baseThreshold * confidenceThreshold

            if priorityHouseholdItems.contains(className) {
                threshold *= 0.7
            }

            for contextObj in contextObjects {
                if let pairedItems = contextPairs[contextObj], pairedItems.contains(className) {
                    threshold *= 0.6
                    break
                }
            }

            guard maxScore > threshold else { continue }

            // YOUR ORIGINAL FILTER MODE CHECK
            if filterMode != "all" {
                let allowedClasses: Set<String> = switch filterMode.lowercased() {
                case "indoor":
                    indoorClasses.union(bothClasses)
                case "outdoor":
                    outdoorClasses.union(bothClasses)
                default:
                    Set(classNames)
                }
                guard allowedClasses.contains(className) else { continue }
            }

            // YOUR ORIGINAL COORDINATE TRANSFORMATION
            let unpadded_x = x_center - Float(padX)
            let unpadded_y = y_center - Float(padY)

            let orig_center_x = unpadded_x / scale
            let orig_center_y = unpadded_y / scale
            let orig_w = box_width / scale
            let orig_h = box_height / scale

            let orig_x = orig_center_x - orig_w / 2
            let orig_y = orig_center_y - orig_h / 2

            let norm_x: Float
            let norm_y: Float
            let norm_w: Float
            let norm_h: Float

            if wasRotated {
                norm_x = 1.0 - (orig_y / Float(originalHeight))
                norm_y = orig_x / Float(originalWidth)
                norm_w = orig_h / Float(originalHeight)
                norm_h = orig_w / Float(originalWidth)
            } else {
                norm_x = orig_x / Float(originalWidth)
                norm_y = orig_y / Float(originalHeight)
                norm_w = orig_w / Float(originalWidth)
                norm_h = orig_h / Float(originalHeight)
            }

            guard norm_w > 0.005, norm_h > 0.005 else { continue }

            let final_x = max(0, min(1, norm_x))
            let final_y = max(0, min(1, norm_y))
            let final_w = max(0.01, min(1 - final_x, norm_w))
            let final_h = max(0.01, min(1 - final_y, norm_h))

            let rect = CGRect(x: CGFloat(final_x), y: CGFloat(final_y),
                              width: CGFloat(final_w), height: CGFloat(final_h))

            let detectionArea = final_w * final_h
            if detectionArea > 0.85 { continue }

            if className == "Human body", detectionArea > 0.3 { continue }

            // REPLACE original detection append with tracking logic
            let detectionKey = "\(className)_\(Int(final_x * 100))_\(Int(final_y * 100))"
            if var existing = trackedDetections[detectionKey] {
                // Update existing detection
                existing.confidence = max(existing.confidence * 0.8, maxScore) // Smooth confidence
                existing.rect = rect
                existing.lastSeen = frameCount
                trackedDetections[detectionKey] = existing
                detections.append(YOLODetection(
                    classIndex: bestClass,
                    className: className,
                    score: existing.confidence,
                    rect: existing.rect
                ))
            } else {
                // Create new tracked detection
                let newDetection = YOLODetection(
                    classIndex: bestClass,
                    className: className,
                    score: maxScore,
                    rect: rect
                )
                trackedDetections[detectionKey] = TrackedDetection(detection: newDetection, frame: frameCount)
                detections.append(newDetection)
            }

            detectionCount += 1
        }

        // YOUR ORIGINAL POST-PROCESSING PIPELINE
        let deduplicatedDetections = removeDuplicates(detections)
        let nmsFiltered = applyNMS(deduplicatedDetections)
        let conflictResolved = resolveConflicts(nmsFiltered)
        updateDetectionHistory(conflictResolved)
        let finalDetections = filterTopDetections(conflictResolved)

        // Clean up old tracked detections every 30 frames
        framesSinceLastCleanup += 1
        if framesSinceLastCleanup > 30 {
            let cutoffFrame = frameCount - 15 // Keep detections for 15 frames
            trackedDetections = trackedDetections.filter { $0.value.lastSeen > cutoffFrame }
            framesSinceLastCleanup = 0
        }

        return Array(finalDetections.prefix(maxDetectionsPerFrame))
    }

    // ALL YOUR ORIGINAL HELPER METHODS - What made it work!

    private func removeDuplicates(_ detections: [YOLODetection]) -> [YOLODetection] {
        let sorted = detections.sorted { $0.score > $1.score }
        var keep: [YOLODetection] = []

        for detection in sorted {
            var isDuplicate = false
            for kept in keep {
                let iou = calculateIoU(rect1: kept.rect, rect2: detection.rect)
                if iou > duplicateIoUThreshold {
                    isDuplicate = true
                    break
                }
            }
            if !isDuplicate {
                keep.append(detection)
            }
        }
        return keep
    }

    private func resolveConflicts(_ detections: [YOLODetection]) -> [YOLODetection] {
        var keep: [YOLODetection] = []
        var skipIndices: Set<Int> = []

        for (i, detection) in detections.enumerated() {
            if skipIndices.contains(i) { continue }

            var shouldKeep = true

            for (j, other) in detections.enumerated() where i != j && !skipIndices.contains(j) {
                let isConflict = conflictingClasses.contains { pair in
                    (pair.0 == detection.className && pair.1 == other.className) ||
                        (pair.1 == detection.className && pair.0 == other.className)
                }

                if isConflict {
                    let iou = calculateIoU(rect1: detection.rect, rect2: other.rect)
                    if iou > 0.8 {
                        if detection.score < other.score {
                            shouldKeep = false
                            break
                        } else {
                            skipIndices.insert(j)
                        }
                    }
                }
            }

            if shouldKeep {
                keep.append(detection)
            }
        }
        return keep
    }

    private func updateDetectionHistory(_ detections: [YOLODetection]) {
        for key in detectionHistory.keys {
            detectionHistory[key] = max(0, (detectionHistory[key] ?? 0) - 1)
        }

        for detection in detections {
            let key = "\(detection.className)_\(Int(detection.rect.midX * 10))_\(Int(detection.rect.midY * 10))"
            detectionHistory[key] = min(5, (detectionHistory[key] ?? 0) + 2)
        }

        detectionHistory = detectionHistory.filter { $0.value > 0 }
    }

    private func applyNMS(_ detections: [YOLODetection]) -> [YOLODetection] {
        let sorted = detections.sorted { $0.score > $1.score }
        var keep: [YOLODetection] = []

        for detection in sorted {
            var shouldKeep = true
            for kept in keep {
                if kept.className == detection.className {
                    let iou = calculateIoU(rect1: kept.rect, rect2: detection.rect)
                    if iou > iouThreshold {
                        shouldKeep = false
                        break
                    }
                }
            }
            if shouldKeep {
                keep.append(detection)
            }
        }
        return keep
    }

    private func filterTopDetections(_ detections: [YOLODetection]) -> [YOLODetection] {
        var classBuckets: [String: [YOLODetection]] = [:]
        for detection in detections {
            classBuckets[detection.className, default: []].append(detection)
        }

        var result: [YOLODetection] = []

        for (className, classDetections) in classBuckets {
            let sorted = classDetections.sorted { $0.score > $1.score }
            let commonObjects = ["Person", "Chair", "Book", "Bottle", "Cup", "Mobile phone", "Plate", "Fork", "Knife", "Spoon"]
            let maxInstances = commonObjects.contains(className) ? 3 : 2
            result.append(contentsOf: sorted.prefix(maxInstances))
        }

        return result.sorted { $0.score > $1.score }
    }

    private func calculateIoU(rect1: CGRect, rect2: CGRect) -> Float {
        let intersection = rect1.intersection(rect2)
        guard !intersection.isNull else { return 0 }

        let intersectionArea = intersection.width * intersection.height
        let union = rect1.width * rect1.height + rect2.width * rect2.height - intersectionArea

        return Float(intersectionArea / union)
    }

    // YOUR ORIGINAL PERIODIC RESET - Essential for stability
    private func performPeriodicReset() {
        detectionHistory.removeAll()
        frameCount = 0
        print("🔄 Performed periodic reset at frame \(frameCount)")
    }

    private static func loadClassNames() -> [String]? {
        for name in ["class_names", "classes", "labels"] {
            if let path = Bundle.main.path(forResource: name, ofType: "txt") {
                return try? String(contentsOfFile: path, encoding: .utf8)
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }
        return nil
    }

    private static func generateDefaultClassNames() -> [String] {
        (0 ..< 601).map { "Class_\($0)" }
    }

    private static func createDummyPixelBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 640, 640, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb
    }

    func reset() {
        processingLock.lock()
        defer { processingLock.unlock() }

        isProcessing = false
        frameCount = 0
        detectionHistory.removeAll()

        performPeriodicReset()
    }
}

extension YOLOv8Processor {
    // Thermal throttling lives in CameraViewModel (frame rate + preset); the
    // processor-side skip machinery was dead code and has been removed.
    func predictWithThermalLimits(
        image: CVPixelBuffer,
        isPortrait: Bool,
        filterMode: String = "all",
        confidenceThreshold: Float = 0.5,
        completion: @escaping @Sendable ([YOLODetection]?) -> Void
    ) {
        predict(image: image, isPortrait: isPortrait, filterMode: filterMode, confidenceThreshold: confidenceThreshold, completion: completion)
    }
}
