extends "res://addons/godot_mcp/tests/test_case.gd"
const Jobs = preload("res://addons/godot_mcp/runtime/process_jobs.gd")

func test_final_output_arriving_at_exit_is_drained() -> void:
	var path := "user://runtime_exit_race.txt"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.close()
	var jobs := Jobs.new()
	jobs.records.x = {"sequence": 0, "output": [], "state": "running"}
	jobs._handles.x = {"pid": 1, "stdio": FileAccess.open(path, FileAccess.READ), "stderr": null}
	var once := {"written": false}
	jobs.process_is_running = func(_pid):
		if not once.written:
			var writer := FileAccess.open(path, FileAccess.WRITE)
			writer.store_string("FINAL_EXIT_DIAGNOSTIC")
			writer.close()
			once.written = true
		return false
	jobs.process_exit_code = func(_pid): return 0
	jobs.poll()
	assert_false(jobs.active("x"))
	assert_eq(jobs.records.x.output.size(), 1)
	if not jobs.records.x.output.is_empty():
		assert_eq(jobs.records.x.output[0].text, "FINAL_EXIT_DIAGNOSTIC")
	jobs.shutdown()
	DirAccess.remove_absolute(path)
