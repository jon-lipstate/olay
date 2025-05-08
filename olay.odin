package olay

import "core:fmt"
import "core:math"
import "core:math/bits"

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

Element :: struct {
	// Core identity
	id:               string,
	hash_id:          u32, // Stable frame-to-frame id

	// Layout geometry
	position:         [2]f32, // x, y coordinates
	size:             [2]f32, // width, height (Actual Size)
	// preferred_size??
	min_size:         [2]f32, // Min width/height constraints
	max_size:         [2]f32, // Max width/height constraints
	padding:          Padding, // left, right, top, bottom padding

	// Element State
	flags:            Element_Flags,

	// Layout behavior
	layout_direction: Layout_Direction, // Horizontal or vertical layout
	sizing_type:      [2]Sizing_Type,
	child_alignment:  [2]Alignment, // How children align in each axis -- Do i need/want this??
	child_gap:        f32, // Gap between children

	// Visual styling
	background_color: Color,
	corner_radius:    [4]f32, // top-left, top-right, bottom-left, bottom-right
	z_index:          i16,

	// Pointer/event handling
	on_hover:         proc(id: u32, pointer_data: Pointer_Data, user_data: rawptr),
	hover_user_data:  rawptr,
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
	Text_Data,
	Image_Data,
	Border_Data,
	Floating_Data,
	Clip_Data,
	Custom_Data,
}

// Enums
Layout_Direction :: enum {
	Horizontal, // LEFT_TO_RIGHT
	Vertical, // TOP_TO_BOTTOM
}

Sizing_Type :: enum {
	Fit, // Size to content
	Grow, // Expand to available space
	Fixed, // Fixed size
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
Text_Data :: struct {
	text:           string,
	font_id:        u16,
	font_size:      u16,
	letter_spacing: u16,
	line_height:    u16,
	text_color:     Color,
	text_alignment: Text_Alignment,
	wrap_mode:      Wrap_Mode,
	measured_lines: [dynamic]Wrapped_Text_Line, // Cached measurement
}

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
	assert(e != nil)

	if e.sizing_type.x == .Fixed && e.sizing_type.y == .Fixed {return} 	// No-Op

	current_width: f32 = e.size.x
	current_height: f32 = e.size.y

	// Layout Dir: Sum on Axis; Max off axis

	has_children := e.children != nil && len(e.children) != 0

	pad, total_gap := calculate_pads_gap(e)

	switch e.layout_direction {
	case .Horizontal:
		if has_children {
			for child, i in e.children {
				current_height = max(current_height, child.size.y)
				current_width += child.size.x
			}
			// add center gaps:
			current_width += e.child_gap * f32(len(e.children) - 1)
		}
		if e.sizing_type.x != .Fixed {
			e.size.x = current_width + pad.x + total_gap
		}
		if e.sizing_type.y != .Fixed {
			e.size.y = current_height + pad.y
		}
	case .Vertical:
		if has_children {
			for child, i in e.children {
				current_width = max(current_width, child.size.x)
				current_height += child.size.y
			}
			// add center gaps:
			current_width += e.child_gap * f32(len(e.children) - 1)
		}
		if e.sizing_type.x != .Fixed {
			e.size.x = current_width + pad.x
		}
		if e.sizing_type.y != .Fixed {
			e.size.y = current_height + pad.y + total_gap
		}
	}

	fmt.println("_close for ", e.id, current_width, current_height)
}

calculate_pads_gap :: proc(e: ^Element) -> (pad: [2]f32, total_gap: f32) {
	pad = {e.padding.left + e.padding.right, e.padding.top + e.padding.bottom}

	if e.children != nil && len(e.children) != 0 {
		total_gap = f32(len(e.children) - 1) * e.child_gap
	}
	return
}

calculate_grow_elements :: proc(e: ^Element) {
	if e.children == nil || len(e.children) == 0 {return}
	pad, total_gap := calculate_pads_gap(e)

	i := e.layout_direction == .Horizontal ? 0 : 1 // primary-axis
	j := i == 0 ? 1 : 0 // cross-axis
	residual_length := e.size[i] - pad[i] - total_gap

	growable := make([dynamic]^Element)
	defer delete(growable) // TODO: temp allocator.. or arena, prob dont need delete; or @static maybe..?
	for child in e.children {
		if child.sizing_type[i] != .Grow {
			residual_length -= child.size[i]
		} else {
			append(&growable, child)
		}
		// Cross-Axis Grow:
		if child.sizing_type[j] == .Grow {
			child.size[j] = e.size[j] - pad[j]
		}
	}
	assert(residual_length >= 0) // FIXME: this could be a 'valid' error state with excess FIXED elements

	if len(growable) == 0 {return}
	// Keep growing the smallest elements incrementally
	// https://youtu.be/by9lQvpvMIc?si=fCGr4iaQVtsABVkw&t=1658
	for residual_length > 0 {
		smallest := growable[0]
		second_smallest: ^Element
		width_to_add := residual_length

		for child in growable {
			if child.size[i] <= smallest.size[i] {
				second_smallest = smallest
				smallest = child
			} else {
				if second_smallest != nil {
					if child.size[i] < second_smallest.size[i] {
						second_smallest = child
					}
				} else {
					second_smallest = child
				}
				if second_smallest != smallest {
					width_to_add = second_smallest.size[i] - smallest.size[i]
				}
			}
		}
		width_to_add = min(width_to_add, residual_length / f32(len(growable)))

		for child in growable {
			if child.size[i] == smallest.size[i] {
				child.size[i] += width_to_add
				residual_length -= width_to_add
			}
		}
	}
}
calculate_grow_recursive :: proc(e: ^Element) {
	calculate_grow_elements(e)
	for child in e.children {
		calculate_grow_recursive(child)
	}
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
calculate_final_layout :: proc(root: ^Element) {
	calculate_grow_recursive(root)
	calculate_positions(root)
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
calculate_positions :: proc(root: ^Element, offset: [2]f32 = 0) {
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

		for child, i in element.children {
			child := element.children[i]
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
