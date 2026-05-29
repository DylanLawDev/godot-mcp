extends Node2D

## Second nested enemy script — gives search_project multiple recursive hits.

const PHASES := 3

var _phase := 1


func advance_phase() -> int:
	_phase = min(PHASES, _phase + 1)
	return _phase


func is_enraged() -> bool:
	return _phase >= PHASES
