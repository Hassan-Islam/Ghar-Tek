#!/bin/bash

# Shopping Bag Icon Generator Script
# This script creates a shopping bag icon using ImageMagick or similar tools

echo "Creating shopping bag icon for GharTek app..."

# Create the main app icon (1024x1024) with blue background and white shopping bag
# This is a placeholder - you would typically use a proper icon design tool

# For now, let's create a simple text-based approach
# Create a temporary SVG file
cat > assets/images/temp_icon.svg << 'EOF'
<svg width="1024" height="1024" xmlns="http://www.w3.org/2000/svg">
  <!-- Blue background circle -->
  <circle cx="512" cy="512" r="512" fill="#2196F3"/>
  
  <!-- Shopping bag -->
  <g transform="translate(256, 256)">
    <!-- Bag body -->
    <path d="M150 200 L362 200 L340 480 L172 480 Z" fill="white" stroke="white" stroke-width="4"/>
    
    <!-- Bag handles -->
    <path d="M190 120 Q190 80 230 80 Q270 80 270 120" fill="none" stroke="white" stroke-width="12" stroke-linecap="round"/>
    <path d="M242 120 Q242 80 282 80 Q322 80 322 120" fill="none" stroke="white" stroke-width="12" stroke-linecap="round"/>
  </g>
</svg>
EOF

echo "Temporary SVG created. Converting to PNG..."

# Note: This requires ImageMagick or similar tool
# For manual creation, you can:
# 1. Use the SVG content above in any SVG editor
# 2. Export as 1024x1024 PNG
# 3. Save as assets/images/app_icon.png

echo "Please manually create the icon using the SVG template above"
echo "Or install ImageMagick and uncomment the conversion line below"

# Uncomment this line if you have ImageMagick installed:
# convert assets/images/temp_icon.svg assets/images/app_icon.png

# For the foreground icon (adaptive), create a version without background
cat > assets/images/temp_foreground.svg << 'EOF'
<svg width="1024" height="1024" xmlns="http://www.w3.org/2000/svg">
  <!-- Shopping bag only (no background) -->
  <g transform="translate(256, 256)">
    <!-- Bag body -->
    <path d="M150 200 L362 200 L340 480 L172 480 Z" fill="#2196F3" stroke="#2196F3" stroke-width="4"/>
    
    <!-- Bag handles -->
    <path d="M190 120 Q190 80 230 80 Q270 80 270 120" fill="none" stroke="#2196F3" stroke-width="12" stroke-linecap="round"/>
    <path d="M242 120 Q242 80 282 80 Q322 80 322 120" fill="none" stroke="#2196F3" stroke-width="12" stroke-linecap="round"/>
  </g>
</svg>
EOF

echo "Foreground SVG created"
echo "Please convert both SVG files to PNG format (1024x1024)"
