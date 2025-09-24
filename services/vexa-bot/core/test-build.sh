#!/bin/bash

echo "🧪 Testing Vexa Bot build process..."

# Test 1: Check if TypeScript compiles
echo "📝 Testing TypeScript compilation..."
npx tsc
if [ $? -eq 0 ]; then
    echo "✅ TypeScript compilation successful"
else
    echo "❌ TypeScript compilation failed"
    exit 1
fi

# Test 2: Check if browser bundle builds
echo "🌐 Testing browser bundle creation..."
node build-browser-utils.js
if [ $? -eq 0 ]; then
    echo "✅ Browser bundle creation successful"
else
    echo "❌ Browser bundle creation failed"
    exit 1
fi

# Test 3: Verify the browser bundle file exists
if [ -f "dist/browser-utils.global.js" ]; then
    echo "✅ browser-utils.global.js file created"
    echo "📊 File size: $(wc -c < dist/browser-utils.global.js) bytes"
else
    echo "❌ browser-utils.global.js file not found"
    exit 1
fi

# Test 4: Verify the bundle contains expected classes
if grep -q "BrowserAudioService" dist/browser-utils.global.js && grep -q "BrowserWhisperLiveService" dist/browser-utils.global.js; then
    echo "✅ Browser utility classes found in bundle"
else
    echo "❌ Browser utility classes missing from bundle"
    exit 1
fi

echo "🎉 All build tests passed! Docker build should work correctly."


