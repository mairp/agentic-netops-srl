package register

// Exported for the external guard test (guard_render_test.go), which drives
// the renderers of internal/render/srl — a package that imports this one.
var (
	FabricFixtures  = fabricFixtures
	ServiceFixtures = serviceFixtures
)

// CheckWriteWithout is CheckWrite against the register with the entry dropped
// removed — the guard's negative control.
func CheckWriteWithout(paths []string, dropped string) error {
	var entries []WriteEntry
	for _, e := range WriteEntries() {
		if e.Path != dropped {
			entries = append(entries, e)
		}
	}
	return checkWriteAgainst(paths, entries)
}
