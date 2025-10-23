local SwimConstants = {
    DesiredVelocityAttribute = "WaterSwimDesiredVelocity",

    InteriorPartName = "ShipInterior",
    InteriorRegionPadding = Vector3.new(4, 6, 4),
    InteriorCacheDuration = 0.35,

    BuoyancyAttachmentName = "SwimmingBuoyancyAttachment",
    LinearVelocityName = "SwimmingLinearVelocity",

    SurfaceHoldOffset = 1,
    SurfaceHoldStiffness = 6,
    SurfaceHoldDamping = 3,

    BaseSwimSpeed = 16,
    MinSwimSpeed = 6,
    MaxHorizontalSpeed = 24,
    MaxVerticalSpeed = 18,
    DepthSlowFactor = 0.2,

    MaxOxygenTime = 20,
    OxygenRecoveryRate = 8,
    DrowningDamage = 10,
    DrowningDamageInterval = 1,

    DesiredVelocityUpdateThresholdSquared = 0.25,
}

return SwimConstants
