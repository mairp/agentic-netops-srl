package register

// Exported for the external guard test (guard_render_test.go), which drives
// the renderers of internal/render/srl — a package that imports this one.
var (
	FabricFixtures  = fabricFixtures
	ServiceFixtures = serviceFixtures
)
