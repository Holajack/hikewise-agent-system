#!/usr/bin/env python3
"""
parse-hierarchy.py - Parse Maestro hierarchy XML and extract structured data.

Usage: python3 parse-hierarchy.py <hierarchy.xml> [--json]

Outputs JSON with:
  totalElements, textElements[], testIds[], buttons[], inputFields[], bounds{}
"""

import sys
import json
import xml.etree.ElementTree as ET


def parse_hierarchy(xml_path):
    """Parse a Maestro hierarchy XML file and extract UI element data."""
    try:
        tree = ET.parse(xml_path)
    except ET.ParseError as e:
        return {"error": f"XML parse error: {e}", "totalElements": 0,
                "textElements": [], "testIds": [], "buttons": [], "inputFields": []}

    root = tree.getroot()

    text_elements = []
    test_ids = []
    buttons = []
    input_fields = []
    total = 0
    bounds = {"width": 0, "height": 0}

    def walk(node):
        nonlocal total
        total += 1

        # Extract common attributes (Maestro uses various attribute names)
        text = (node.get("text") or node.get("hintText") or
                node.get("accessibilityText") or "").strip()
        test_id = (node.get("resource-id") or node.get("testId") or
                   node.get("accessibilityIdentifier") or "").strip()
        node_class = (node.get("class") or node.get("type") or
                      node.tag or "").strip()
        clickable = node.get("clickable", "false").lower() == "true"
        enabled = node.get("enabled", "true").lower() == "true"
        focused = node.get("focused", "false").lower() == "true"

        # Bounds parsing: "[x1,y1][x2,y2]" format
        bounds_str = node.get("bounds", "")
        if bounds_str:
            try:
                parts = bounds_str.replace("][", ",").strip("[]").split(",")
                if len(parts) == 4:
                    x2, y2 = int(parts[2]), int(parts[3])
                    if x2 > bounds["width"]:
                        bounds["width"] = x2
                    if y2 > bounds["height"]:
                        bounds["height"] = y2
            except (ValueError, IndexError):
                pass

        # Collect text elements (non-empty, visible text)
        if text and len(text) < 500:
            text_elements.append(text)

        # Collect testIds
        if test_id:
            test_ids.append(test_id)

        # Identify buttons (clickable elements with text, or button-like classes)
        button_classes = ("button", "btn", "touchable", "pressable",
                          "clickable", "imagebutton")
        is_button = (clickable and text) or any(
            bc in node_class.lower() for bc in button_classes
        )
        if is_button and text:
            buttons.append({
                "text": text,
                "testId": test_id or None,
                "enabled": enabled,
                "class": node_class
            })

        # Identify input fields
        input_classes = ("edittext", "textfield", "textinput", "input")
        is_input = any(ic in node_class.lower() for ic in input_classes)
        if is_input:
            input_fields.append({
                "hint": text or None,
                "testId": test_id or None,
                "focused": focused,
                "class": node_class
            })

        # Recurse into children
        for child in node:
            walk(child)

    walk(root)

    # Deduplicate while preserving order
    seen_text = set()
    unique_text = []
    for t in text_elements:
        if t not in seen_text:
            seen_text.add(t)
            unique_text.append(t)

    seen_ids = set()
    unique_ids = []
    for tid in test_ids:
        if tid not in seen_ids:
            seen_ids.add(tid)
            unique_ids.append(tid)

    return {
        "totalElements": total,
        "textElements": unique_text,
        "testIds": unique_ids,
        "buttons": buttons,
        "inputFields": input_fields,
        "bounds": bounds
    }


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 parse-hierarchy.py <hierarchy.xml>", file=sys.stderr)
        sys.exit(1)

    result = parse_hierarchy(sys.argv[1])
    print(json.dumps(result, indent=2))
