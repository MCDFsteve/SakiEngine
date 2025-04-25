using Microsoft.Xna.Framework;
using SakiEngine.Core.SceneGraph; // For UIRectN, SceneObject
using SakiEngine.Core.Text; // For SkiaTextElement, Alignment
using SakiEngine.Core.Utils; // Add this for UIRectN
using System; // For Action, EventHandler
using System.Diagnostics; // For DebuggerNonUserCode
using System.Linq; // For FirstOrDefault

namespace SakiEngine.Core.UI
{
    /// <summary>
    /// Provides helper methods for creating common UI elements.
    /// </summary>
    public static class UIHelper
    {
        /// <summary>
        /// Creates a Button with a centered text label, adds it to a parent container, 
        /// and optionally wires up an OnClick event handler.
        /// </summary>
        /// <param name="parent">The UIElement to add the button to.</param>
        /// <param name="id">The unique identifier for the button.</param>
        /// <param name="layerId">The layer ID for rendering order.</param>
        /// <param name="rect">The normalized rectangle (UIRectN) defining the button's position and size.</param>
        /// <param name="text">The text to display on the button. If null or empty, no text label is created.</param>
        /// <param name="onClickAction">The action to perform when the button is clicked. Can be null.</param>
        /// <param name="backgroundColor">Optional background color for the button.</param>
        /// <param name="hoverColor">Optional color when the mouse hovers over the button.</param>
        /// <param name="pressedColor">Optional color when the button is pressed.</param>
        /// <param name="textColor">Optional text color.</param>
        /// <param name="textSize">Optional text size (relative to reference height). Defaults to 24.</param>
        /// <param name="fontName">Optional font name. If null or empty, uses the default font.</param>
        /// <returns>The created Button instance.</returns>
        [DebuggerNonUserCode] // Avoid stepping into this helper in debugger
        public static Button CreateAndAddButton(
            UIElement parent,
            string id,
            int layerId,
            UIRectN rect,
            string? text = null,
            Action<UIElement>? onClickAction = null,
            Color? backgroundColor = null,
            Color? hoverColor = null,
            Color? pressedColor = null,
            Color? textColor = null,
            float textSize = 24f,
            string? fontName = null
        )
        {
            // 1. Create the button
            var button = new Button(id, layerId, rect);

            // 2. Set optional colors (using default Button values if null)
            if (backgroundColor.HasValue) button.BackgroundColor = backgroundColor.Value;
            if (hoverColor.HasValue) button.HoverColor = hoverColor.Value;
            if (pressedColor.HasValue) button.PressedColor = pressedColor.Value;

            // 3. Create and add text label if text is provided
            if (!string.IsNullOrEmpty(text))
            {
                // Pass text to constructor, use UIRectN.FullScreen for text rect
                var textElement = new SkiaTextElement(
                    $"{id}_Text", // Auto-generate text ID
                    layerId, // Use same layer as button or adjust if needed
                    UIRectN.FullScreen, // Use FullScreen static property
                    text // Pass the text parameter
                )
                {
                    // Text = text, // Text is set via constructor now
                    Alignment = TextAlignment.Center, // Use the single Alignment property
                    // Vertical alignment is implicitly center due to UIRectN.FullScreen?
                    TextColor = textColor ?? Color.White, // Default to white if not specified
                    // FontSize will be set by SetFont
                    // FontName will be set by SetFont
                };
                // Use SetFont to apply size and optional font name (handles defaulting)
                textElement.SetFont(fontName, textSize);
                button.AddChild(textElement);
            }

            // 4. Wire up the click event
            if (onClickAction != null)
            {
                button.OnClick += onClickAction;
            }

            // 5. Add the button to the parent container
            parent.AddChild(button);

            // 6. Return the created button for potential further chaining or access
            return button;
        }

        /// <summary>
        /// Helper to safely get the text from a button's child SkiaTextElement.
        /// </summary>
        public static string? GetButtonText(Button button)
        {
            return button?.Children.OfType<SkiaTextElement>().FirstOrDefault()?.Text;
        }

        /// <summary>
        /// Helper to safely set the text of a button's child SkiaTextElement.
        /// </summary>
        public static void SetButtonText(Button button, string text)
        {
            var textElement = button?.Children.OfType<SkiaTextElement>().FirstOrDefault();
            if (textElement != null)
            {
                textElement.Text = text;
            }
        }

        // Future helper methods can go here.
    }
} 