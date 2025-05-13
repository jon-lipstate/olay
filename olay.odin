package olay

import "core:fmt"
import "core:math"

Element_Flag :: enum {
	// Layout type
	Is_Grid, // If false, uses flex layout

	// Flow direction (for flex)
	Flow_Horizontal, // LEFT_TO_RIGHT
	Flow_Vertical, // TOP_TO_BOTTOM

	// Element capabilities
	Is_Scrollable_H, // Can scroll horizontally
	Is_Scrollable_V, // Can scroll vertically
	Is_Floating, // Element floats above normal layout
	Has_Border, // Element has a border

	// Behavior
	Pointer_Passthrough, // If false, captures pointer events

	// State
	Is_Hovered, // Element is being hovered
	Is_Pressed, // Element is being pressed
	Is_Focused, // Element has keyboard focus
	Is_Hidden, // Element is _not_ visible
	Is_Disabled, // Element is enabled

	// Optimization
	Needs_Layout, // Element needs layout recalculation
	Needs_Redraw, // Element needs visual redraw
}

Element_Flags :: bit_set[Element_Flag]


Padding :: struct {
	left, right, top, bottom: f32,
}

Sizing_Axis :: struct {
	mode: Sizing_Mode,
	size: struct #raw_union {
		using min_max: Min_Max,
		percent:       f32,
	},
}
Min_Max :: struct {
	min, max: f32,
}

Element :: struct {
	// Core identity
	id:               string,
	hash_id:          u32, // Stable frame-to-frame id

	// Layout geometry
	position:         [2]f32, // x, y coordinates (Computed)
	size:             [2]f32, // width, height (Computed)
	constraints:      [2]Sizing_Axis,
	padding:          Padding,

	// Element State
	flags:            Element_Flags,

	// Layout behavior
	layout_direction: Layout_Direction, // Horizontal or vertical layout
	child_alignment:  [2]Alignment, // How children align in each axis
	child_gap:        f32, // Gap between children

	// Visual styling
	background_color: Color,
	corner_radius:    [4]f32, // top-left, top-right, bottom-left, bottom-right
	z_index:          i16,

	// Pointer/event handling
	// on_hover:         proc(id: u32, pointer_data: Pointer_Data, user_data: rawptr),
	// hover_user_data:  rawptr,
	pointer_capture:  Pointer_Capture_Mode,

	// Hierarchy
	parent:           ^Element,
	children:         [dynamic]^Element,
	clip_parent:      ^Element, // Parent for clipping/scrolling

	// Element-specific data
	data:             Element_Data,

	// User data
	user_data:        rawptr,
}

// Type-specific data in union
Element_Data :: union {
	^Text_Data,
	^Image_Data,
	^Border_Data,
	^Floating_Data,
	^Clip_Data,
	^Custom_Data,
}

// Enums
Layout_Direction :: enum {
	Horizontal, // LEFT_TO_RIGHT
	Vertical, // TOP_TO_BOTTOM
}

Sizing_Mode :: enum {
	Fit, // Size to content
	Grow, // Expand to available space
	Fixed, // Fixed size
	Percent,
}

Alignment :: enum {
	Start, // Left/Top
	Center, // Center
	End, // Right/Bottom
}

Pointer_Capture_Mode :: enum {
	Capture,
	Passthrough,
}

// Element-specific data structs


Image_Data :: struct {
	image_data:        rawptr,
	source_dimensions: [2]f32,
}

Border_Data :: struct {
	border_width: [5]f32, // left, right, top, bottom, between_children
	border_color: Color,
}

Floating_Data :: struct {
	attach_to:        Floating_Attach_To,
	attach_parent_id: u32,
	attach_points:    [2]Attach_Point,
	offset:           [2]f32,
	expand:           [2]f32, // Extra invisible space around element
}

Clip_Data :: struct {
	horizontal:      bool,
	vertical:        bool,
	scroll_position: [2]f32,
	content_size:    [2]f32,
	momentum:        [2]f32, // For momentum scrolling
}

Custom_Data :: distinct rawptr

// Additional types for specific elements
Text_Alignment :: enum {
	Left,
	Center,
	Right,
}

Wrap_Mode :: enum {
	Words,
	Newlines,
	None,
}

Floating_Attach_To :: enum {
	None,
	Parent,
	Element_With_ID,
	Root,
}

Attach_Point :: enum {
	Left_Top,
	Left_Center,
	Left_Bottom,
	Center_Top,
	Center_Center,
	Center_Bottom,
	Right_Top,
	Right_Center,
	Right_Bottom,
}

Wrapped_Text_Line :: struct {
	dimensions: [2]f32,
	line:       string,
}

Color :: [4]f32

Pointer_Data :: struct {
	position: [2]f32,
	state:    Pointer_State,
}

Pointer_State :: enum {
	Pressed_This_Frame,
	Pressed,
	Released_This_Frame,
	Released,
}

@(deferred_out = _close_element)
push_element :: proc(parent: ^Element, id: string) -> ^Element {
	element := new(Element)
	element.children = make([dynamic]^Element)
	element.id = id
	element.hash_id = hash_string(id)

	if parent != nil {
		append(&parent.children, element)
	}
	return element
}
// This post-processes the element to compute sizes in Post-Order DFS:
_close_element :: proc(e: ^Element) {
	fit_width(e) // TODO: script based; eg cjk that go vertically flip the process to height
	fmt.println("_close for ", e.id, e.size.x, e.size.y)
}

// Computes the required width of this element based on its children
fit_width :: proc(e: ^Element) {
	current_width: f32 = e.size.x
	pad, total_gap := calculate_pads_gap(e)

	switch e.layout_direction {
	case .Horizontal:
		for child in e.children {
			current_width += child.size.x
			e.constraints.x.size.min += child.constraints.x.size.min
		}
		// add center gaps:
		current_width += e.child_gap * f32(len(e.children) - 1)
		if e.constraints.x.mode != .Fixed {
			e.size.x = current_width + pad.x + total_gap
		}
	case .Vertical:
		for child in e.children {
			current_width = max(current_width, child.size.x)
			e.constraints.x.size.min = max(e.constraints.x.size.min, child.constraints.x.size.min)
		}
		if e.constraints.x.mode != .Fixed {
			e.size.x = current_width + pad.x
		}
	}
}
// Computes the required height of this element based on its children
fit_height :: proc(e: ^Element) {
	assert(e != nil)

	current_height: f32 = e.size.y

	// Handle Text & Image elements specially
	if text_data, is_text := e.data.(^Text_Data); is_text {
		if len(text_data.measured_lines) > 0 {
			// Height is sum of all wrapped lines
			text_height: f32 = 0
			for line in text_data.measured_lines {
				text_height += line.dimensions.y
			}

			if e.constraints.y.mode != .Fixed {
				e.size.y = text_height
			}
		}
		return // For text elements, we're done after setting height
	}

	if image_data, is_image := e.data.(^Image_Data); is_image {
		// If we have an image with a fixed aspect ratio, and width is determined
		if image_data.source_dimensions.x > 0 &&
		   image_data.source_dimensions.y > 0 &&
		   e.size.x > 0 {
			aspect_ratio := image_data.source_dimensions.y / image_data.source_dimensions.x
			calculated_height := e.size.x * aspect_ratio

			if e.constraints.y.mode != .Fixed {
				e.size.y = calculated_height
			}
			return
		}
	}

	// Layout Dir: Sum on Axis; Max off axis
	pad, total_gap := calculate_pads_gap(e)

	switch e.layout_direction {
	case .Horizontal:
		for child in e.children {
			current_height = max(current_height, child.size.y)
			e.constraints.y.size.max = max(e.constraints.y.size.max, child.constraints.y.size.max)
		}
		if e.constraints.y.mode != .Fixed {
			e.size.y = current_height + pad.y
		}
	case .Vertical:
		for child in e.children {
			current_height += child.size.y
			e.constraints.y.size.max += child.constraints.y.size.max
		}
		// add center gaps:
		current_height += e.child_gap * f32(len(e.children) - 1)
		if e.constraints.y.mode != .Fixed {
			e.size.y = current_height + pad.y + total_gap
		}
	}

	// Apply min/max constraints
	if e.constraints.y.mode != .Percent {
		min_height := e.constraints.y.size.min
		max_height := e.constraints.y.size.max == 0 ? math.F32_MAX : e.constraints.y.size.max
		e.size.y = clamp(e.size.y, min_height, max_height)
	}
}

// Depth First Traversal of `fit_height`
recompute_heights :: proc(e: ^Element) {
	for child in e.children {
		recompute_heights(child)
	}
	fit_height(e)
}

wrap_text :: proc(e: ^Element, recursive := true) {
	// TODO: IMPLE
	if recursive {
		for child in e.children {
			wrap_text(child, recursive)
		}
	}
}

// Handles both growing and shrinking elements along a given axis
grow_axis :: proc(e: ^Element, x_axis: bool, recursive := true) {
	if e == nil || e.children == nil || len(e.children) == 0 {
		return
	}
	// Grow Explanation:
	// https://youtu.be/by9lQvpvMIc?si=fCGr4iaQVtsABVkw&t=1658

	// Shrink Explanation:
	// https://youtu.be/by9lQvpvMIc?si=i9LrVD6JyI3iU0Eb&t=2082

	axis := x_axis ? 0 : 1
	// cross_axis := x_axis ? 1 : 0

	// Determine if we're operating on the primary layout axis
	is_primary_axis :=
		(x_axis && e.layout_direction == .Horizontal) ||
		(!x_axis && e.layout_direction == .Vertical)

	// Calculate available space and required content size
	pad, total_gap := calculate_pads_gap(e)
	available_space := e.size[axis] - pad[axis] - (is_primary_axis ? total_gap : 0)
	required_space: f32 = 0

	// Track growable and shrinkable children
	growable := make([dynamic]^Element)
	shrinkable := make([dynamic]^Element)
	defer delete(growable)
	defer delete(shrinkable)

	// Calculate required space and identify growable/shrinkable elements
	for child in e.children {
		if is_primary_axis {
			// For primary layout axis, sum sizes
			required_space += child.size[axis]

			// Identify growable elements
			if child.constraints[axis].mode == .Grow {
				append(&growable, child)
			}

			// Identify shrinkable elements (those above min size)
			if child.size[axis] > child.constraints[axis].size.min {
				append(&shrinkable, child)
			}
		} else {
			// For cross-axis, find maximum size
			required_space = max(required_space, child.size[axis])

			// Cross-axis growth for each child
			if child.constraints[axis].mode == .Grow {
				child.size[axis] = available_space
				child.size[axis] = clamp(
					child.size[axis],
					child.constraints[axis].size.min,
					child.constraints[axis].size.max == 0 ? math.F32_MAX : child.constraints[axis].size.max,
				)
			}
		}
	}

	// For primary layout axis, handle growing/shrinking
	if is_primary_axis {
		difference := available_space - required_space

		if difference > 0 && len(growable) > 0 {
			// Need to grow elements
			distribute_extra_space(growable, difference, axis)
		} else if difference < 0 && len(shrinkable) > 0 {
			// Need to shrink elements
			distribute_negative_space(&shrinkable, difference, axis)
		}
	}

	if recursive {
		for child in e.children {
			grow_axis(child, x_axis, recursive)
		}
	}
}

// Helper for distributing extra space
distribute_extra_space :: proc(elements: [dynamic]^Element, extra_space: f32, axis: int) {
	if len(elements) == 0 || extra_space <= 0 {return}

	remaining_space := extra_space
	remaining_elements := len(elements)

	for remaining_space > 0 && remaining_elements > 0 {
		// Find smallest and second smallest elements
		smallest := elements[0]
		second_smallest: ^Element

		for element in elements {
			if element.size[axis] <= smallest.size[axis] {
				second_smallest = smallest
				smallest = element
			} else if second_smallest == nil || element.size[axis] < second_smallest.size[axis] {
				second_smallest = element
			}
		}

		// Space to add per element
		size_to_add := remaining_space / f32(remaining_elements)

		// If we have a second smallest with different size, limit growth
		if second_smallest != nil && second_smallest.size[axis] > smallest.size[axis] {
			size_difference := second_smallest.size[axis] - smallest.size[axis]
			if size_difference < size_to_add {
				size_to_add = size_difference
			}
		}

		// Apply growth to smallest elements
		space_distributed := f32(0)

		for element in elements {
			if element.size[axis] == smallest.size[axis] {
				old_size := element.size[axis]

				// Apply growth up to max constraint
				max_size :=
					element.constraints[axis].size.max == 0 ? math.F32_MAX : element.constraints[axis].size.max
				element.size[axis] = min(element.size[axis] + size_to_add, max_size)

				// Track distributed space
				space_distributed += element.size[axis] - old_size

				// If we hit the max, consider this element no longer growable
				if element.size[axis] >= max_size {
					remaining_elements -= 1
				}
			}
		}

		// Update remaining space
		remaining_space -= space_distributed

		// If we didn't distribute any space, we're done
		if space_distributed <= 0 {break}
	}
}

// Helper for distributing negative space
distribute_negative_space :: proc(elements: ^[dynamic]^Element, negative_space: f32, axis: int) {
	if len(elements) == 0 || negative_space >= 0 {return}

	remaining_space := negative_space

	for remaining_space < 0 && len(elements) > 0 {
		// Find largest and second largest elements
		largest := elements[0]
		second_largest: ^Element = nil

		for element in elements {
			if element.size[axis] >= largest.size[axis] {
				second_largest = largest
				largest = element
			} else if second_largest == nil || element.size[axis] > second_largest.size[axis] {
				second_largest = element
			}
		}

		// Space to reduce per element
		size_to_reduce := -remaining_space / f32(len(elements))

		// If we have a second largest with different size, limit reduction
		if second_largest != nil && second_largest.size[axis] < largest.size[axis] {
			size_difference := largest.size[axis] - second_largest.size[axis]
			if size_difference < size_to_reduce {
				size_to_reduce = size_difference
			}
		}

		// Apply reduction to largest elements
		space_distributed := f32(0)

		// Use reverse loop to safely remove elements
		#reverse for element, i in elements {
			if element.size[axis] == largest.size[axis] {
				old_size := element.size[axis]

				// Apply reduction down to min constraint
				min_size := element.constraints[axis].size.min
				element.size[axis] = max(element.size[axis] - size_to_reduce, min_size)

				// Track distributed space
				space_distributed += old_size - element.size[axis]

				// If we hit the min, remove this element from consideration
				if element.size[axis] <= min_size {
					unordered_remove(elements, i)
				}
			}
		}

		remaining_space += space_distributed

		// If we didn't distribute any space, we're done
		if space_distributed <= 0 {break}
	}
}

set_position :: proc(e: ^Element) {
	// TODO: IMPLE
}


calculate_pads_gap :: proc(e: ^Element) -> (pad: [2]f32, total_gap: f32) {
	pad = {e.padding.left + e.padding.right, e.padding.top + e.padding.bottom}

	if e.children != nil && len(e.children) != 0 {
		total_gap = f32(len(e.children) - 1) * e.child_gap
	}
	return
}

hash_string :: proc(key: string, offset: u32 = 0, seed: u32 = 0) -> u32 {
	hash, base := u32(0), seed

	for b in transmute([]u8)key {
		base += u32(b)
		base += (base << 10)
		base ~= (base >> 6)
	}

	hash = base
	hash += offset
	hash += (hash << 10)
	hash ~= (hash >> 6)

	hash += (hash << 3)
	base += (base << 3)
	hash ~= (hash >> 11)
	base ~= (base >> 11)
	hash += (hash << 15)
	base += (base << 15)

	return hash
}

// 'main' layout fns
compress_children_along_axis :: proc(e: ^Element, x_axis: bool, total_size_to_distribute: f32)
size_containers_along_axis :: proc(e: ^Element, x_axis: bool)

// TODO: return hash so user can skip re-render if not dirty?
compute_layout :: proc(root: ^Element) -> []Render_Command {
	// 1. Compute Fit Sizing Widths 
	// (`fit_width` is already executed via push_element/_close_element)
	// 2. Compute Text Wrapping and Update Width/Height
	wrap_text(root)
	// 3. BFS: Grow/Shrink widths
	grow_axis(root, true) // x-axis
	// 4. DFS: Fit-Heights:
	recompute_heights(root)
	// 5. BFS
	grow_axis(root, false) // y-axis
	// 6. BFS: Calculate Positions & Alignments
	compute_positions(root)
	// 7. Generate Draw Commands
	return generate_render_commands(root)
}

generate_render_commands :: proc(root: ^Element) -> []Render_Command {
	commands := make([dynamic]Render_Command)
	return commands[:]
}

Render_Command :: struct {
	type:             Render_Command_Type,
	bounding_box:     [4]f32, // x, y, width, height
	element_id:       u32,
	z_index:          i16,
	background_color: Color,
	corner_radius:    [4]f32,
	data:             union {
		Text_Line_Data,
		Image_Data,
		Border_Data,
		Clip_Data,
	},
}

Text_Line_Data :: struct {
	text:           string,
	font_id:        u16,
	font_size:      u16,
	letter_spacing: u16,
	text_color:     Color,
}

Render_Command_Type :: enum {
	None,
	Rectangle,
	Border,
	Text,
	Image,
	Custom,
	Scissor_Start,
	Scissor_End,
}
// Layout Computation:
// 1. Compute Fit Sizing Widths
// 2. Compute Grow Widths
// 3. Compute Wrap Text
// 4. Compute Fit Sizing Heights
// 5. Compute Grow Heights
// 6. Calc Positions & Alignments
// 7. Draw Commands


// do 'fit' on first dfs pass
// do 'grow' on 2nd bfs pass


// TODO: collapse into single call ?? seems unneeded to be split
compute_positions :: proc(root: ^Element, offset: [2]f32 = 0) {
	root.position = offset
	calculate_element_positions(root)
}

calculate_element_positions :: proc(element: ^Element) {
	// positions are calculated from the parent:
	if element == nil || element.children == nil || len(element.children) == 0 {
		return
	}

	// Calculate positions based on flow direction
	if .Flow_Horizontal in element.flags {
		// Assumes: Left-To-Right
		current_x := element.position.x + element.padding.left // Start at left padding

		for child in element.children {
			child.position.x = current_x

			// TODO: Alignment - Assume Top-Aligned for now
			child.position.y = element.position.y + element.padding.top
			current_x += child.size.x + element.child_gap
			calculate_element_positions(child)
		}
	} else {
		unimplemented("FLOW VERTICAL")
	}
}
