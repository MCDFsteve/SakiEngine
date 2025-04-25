using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using Microsoft.Xna.Framework.Input;
using SakiEngine.Core.GameCore;
using SakiEngine.Core.SceneGraph;
using SakiEngine.Core.Text;
using SakiEngine.Core.Utils;
using System;
using System.Collections.Generic;
using System.Linq;

namespace SakiEngine.Core.UI
{
    /// <summary>
    /// Delegate for the selection changed event.
    /// </summary>
    public delegate void SelectionChangedHandler(int selectedIndex, string? selectedItem);

    /// <summary>
    /// Represents a dropdown menu (ComboBox) UI element.
    /// </summary>
    public class Dropdown : UIElement
    {
        // --- Event ---
        /// <summary>
        /// Occurs when the selected item changes.
        /// </summary>
        public event SelectionChangedHandler? OnSelectionChanged;

        // --- Configuration ---
        public Color DropdownBackgroundColor { get; set; } = new Color(60, 60, 60, 230); // Background for the dropdown list
        public Color ItemHoverColor { get; set; } = new Color(80, 80, 80, 230);
        public Color SelectedItemColor { get; set; } = new Color(100, 150, 100, 220); // Highlight color for the selected item in the list
        public float ItemHeightRatio { get; set; } = 1.0f; // Height of each item relative to the main dropdown height
        public int MaxVisibleItems { get; set; } = 5; // Max items visible without scrolling (TODO: Scrolling not implemented yet)

        // --- State ---
        private readonly List<string> _items = new List<string>();
        private int _selectedIndex = -1;
        private bool _isExpanded = false;
        private string _currentFontName = "default";
        private float _currentFontSize = 16f;
        private int _hoveredItemIndex = -1; // Index of the item mouse is hovering over in the list

        // --- Internal Elements (Simplified for now) ---
        // We need a way to display the current selection and handle clicks
        // Let's use internal drawing for now, maybe add child Button later
        private Rectangle _mainBounds; // Bounds of the main dropdown box
        private Rectangle _arrowBounds; // Bounds for the dropdown arrow indicator
        private List<Rectangle> _itemBounds = new List<Rectangle>(); // Bounds for each item in the expanded list

        // --- Drawing ---
        public override void Draw(SpriteBatch spriteBatch, int screenWidth, int screenHeight)
        {
            if (!Visible) return;

            // Draw the main box and arrow (non-overlay parts)
            _mainBounds = GetScreenRect(screenWidth, screenHeight);
            float arrowWidth = _mainBounds.Height * 0.8f;
            _arrowBounds = new Rectangle(_mainBounds.Right - (int)arrowWidth - 2, _mainBounds.Y + (_mainBounds.Height - (int)arrowWidth) / 2, (int)arrowWidth, (int)arrowWidth);
            Rectangle mainTextArea = new Rectangle(_mainBounds.X + 5, _mainBounds.Y, _mainBounds.Width - _arrowBounds.Width - 10, _mainBounds.Height);

            base.Draw(spriteBatch, screenWidth, screenHeight); // Draws BackgroundColor

            string? displayItem = SelectedItem ?? "";
            if (!string.IsNullOrEmpty(displayItem))
            {
                 var textRenderer = GameInstance.Instance.TextRenderer;
                 if (textRenderer != null)
                 {
                     float scaledFontSize = _currentFontSize * (GameInstance.InternalHeight / GameInstance.ReferenceHeight);
                     Vector2 textSize = textRenderer.MeasureText(displayItem, _currentFontName, scaledFontSize);
                     float textY = mainTextArea.Y + (mainTextArea.Height - textSize.Y) / 2f;
                     var textBlock = textRenderer.GetOrRenderTextBlock(displayItem, _currentFontName, scaledFontSize, ForegroundColor);
                     if(textBlock?.Texture != null)
                     {
                         spriteBatch.Draw(textBlock.Texture, new Vector2(mainTextArea.X, textY), null, ForegroundColor * Alpha, 0f, Vector2.Zero, 1.0f, SpriteEffects.None, 0f);
                     }
                 }
            }

            DrawArrow(spriteBatch, _arrowBounds, ForegroundColor * Alpha);

            // If expanded, REGISTER the list drawing action for the overlay pass
            if (_isExpanded && _items.Count > 0)
            {
                // Register the method to draw the expanded list in the overlay pass
                // Pass the necessary parameters via the delegate capture
                 GameInstance.Instance.RegisterOverlayDraw(DrawExpandedList);
                 // Note: CheckMouseState still needs to calculate bounds for interaction
                 // Maybe pre-calculate bounds needed for drawing here?
                 CalculateExpandedListBounds(screenWidth, screenHeight); // Pre-calculate bounds needed by DrawExpandedList
            }
            else
            {
                 // Ensure item bounds are cleared if not expanded
                 _itemBounds.Clear();
            }
        }

        // Pre-calculate bounds needed for drawing and interaction
        private Rectangle _expandedListBounds; // Store calculated list bounds
        private void CalculateExpandedListBounds(int screenWidth, int screenHeight)
        {
             // Use _mainBounds which should be up-to-date from the Draw call
             float itemPixelHeight = _mainBounds.Height * ItemHeightRatio;
             int itemCount = Math.Min(_items.Count, MaxVisibleItems);
             int listHeight = (int)(itemCount * itemPixelHeight);
             _expandedListBounds = new Rectangle(_mainBounds.X, _mainBounds.Bottom + 1, _mainBounds.Width, listHeight);
            
             // Calculate individual item bounds based on the list bounds
             _itemBounds.Clear();
             for (int i = 0; i < itemCount; i++)
             {
                  float itemY = _expandedListBounds.Y + i * itemPixelHeight;
                  Rectangle itemRect = new Rectangle(_expandedListBounds.X, (int)itemY, _expandedListBounds.Width, (int)itemPixelHeight);
                  _itemBounds.Add(itemRect);
             }
        }

        /// <summary>
        /// Draws the expanded list part of the dropdown.
        /// This is registered as an overlay draw action.
        /// </summary>
        private void DrawExpandedList(SpriteBatch spriteBatch, int screenWidth, int screenHeight)
        {
             // Note: screenWidth/screenHeight here are the internal resolution passed from GameInstance
             if (!_isExpanded || _items.Count == 0) return; // Should not happen if registered correctly, but safety check

            // Use pre-calculated bounds
            Rectangle listBounds = _expandedListBounds;

            // Draw list background
            spriteBatch.Draw(GameInstance.Instance.WhitePixelTexture, listBounds, DropdownBackgroundColor * Alpha);

            // Draw items using pre-calculated item bounds
            var textRenderer = GameInstance.Instance.TextRenderer;
            for (int i = 0; i < _itemBounds.Count; i++) // Use _itemBounds directly
            {
                Rectangle itemRect = _itemBounds[i];

                // Draw item background (hover state)
                Color itemBgColor = Color.Transparent;
                if (i == _hoveredItemIndex) itemBgColor = ItemHoverColor;
                if(itemBgColor.A > 0)
                     spriteBatch.Draw(GameInstance.Instance.WhitePixelTexture, itemRect, itemBgColor * Alpha);

                // Draw item text (ensure index is valid for _items)
                if (i < _items.Count && textRenderer != null)
                {
                    string itemText = _items[i];
                    float itemScaledFontSize = _currentFontSize * (GameInstance.InternalHeight / GameInstance.ReferenceHeight);
                    Vector2 itemTextSize = textRenderer.MeasureText(itemText, _currentFontName, itemScaledFontSize);
                    float itemTextY = itemRect.Y + (itemRect.Height - itemTextSize.Y) / 2f;
                    var itemTextBlock = textRenderer.GetOrRenderTextBlock(itemText, _currentFontName, itemScaledFontSize, ForegroundColor);
                    if(itemTextBlock?.Texture != null)
                    {
                        spriteBatch.Draw(itemTextBlock.Texture, new Vector2(itemRect.X + 5, itemTextY), null, ForegroundColor * Alpha, 0f, Vector2.Zero, 1.0f, SpriteEffects.None, 0f);
                    }
                }
            }
        }

        // Helper to draw a simple down arrow without Primitives2D
        private void DrawArrow(SpriteBatch spriteBatch, Rectangle bounds, Color color)
        {
            var texture = GameInstance.Instance.WhitePixelTexture;
            // REMOVE unused variable
            // int thick = 1; // Thickness of the lines

            // Calculate points for a downward arrow
            // Vector2 top = new Vector2(bounds.Center.X, bounds.Top + bounds.Height * 0.3f);
            // Vector2 left = new Vector2(bounds.Left + bounds.Width * 0.2f, bounds.Bottom - bounds.Height * 0.3f);
            // Vector2 right = new Vector2(bounds.Right - bounds.Width * 0.2f, bounds.Bottom - bounds.Height * 0.3f);

            // A simpler filled square/rectangle might be easier
             Rectangle arrowRect = new Rectangle(bounds.Center.X - bounds.Width / 4, bounds.Center.Y - bounds.Height / 8, bounds.Width / 2, bounds.Height / 4);
             spriteBatch.Draw(texture, arrowRect, color);
        }

        // --- Interaction ---
        protected override void CheckMouseState()
        {
            var mouseState = Mouse.GetState();
            var rawMousePos = mouseState.Position;
            bool isClick = mouseState.LeftButton == ButtonState.Pressed && _previousMouseState.LeftButton == ButtonState.Released;

            // Map mouse position to internal rendering space (like in Button)
            Point internalMousePos = Point.Zero;
            bool mouseInsideRenderTarget = false;
            var destRect = GameInstance.Instance.ResolutionManager.GetOutputDestinationRectangle();

            // TODO: Refactor mouse mapping logic into a shared utility or service?
            // --- macOS Fullscreen Fix (like in Button) ---
            if (DisplayUtils.IsLikelyNotchedDisplay() &&
                GameInstance.Instance.GraphicsDeviceManager.IsFullScreen)
            {
                rawMousePos = new Point(rawMousePos.X, rawMousePos.Y - 36); 
            }
            // -------------------------------------

            if (destRect.Contains(rawMousePos))
            {
                mouseInsideRenderTarget = true;
                float mouseInDestX = rawMousePos.X - destRect.X;
                float mouseInDestY = rawMousePos.Y - destRect.Y;
                float scaleX = (destRect.Width > 0) ? GameInstance.InternalWidth / (float)destRect.Width : 0f;
                float scaleY = (destRect.Height > 0) ? GameInstance.InternalHeight / (float)destRect.Height : 0f;
                internalMousePos = new Point((int)(mouseInDestX * scaleX), (int)(mouseInDestY * scaleY));
            }

            // Reset hover states
            IsHovered = false; 
            // Keep previous hoveredItemIndex to check if mouse moved outside list
            int previousHoveredItemIndex = _hoveredItemIndex;
            _hoveredItemIndex = -1;
            
            if (mouseInsideRenderTarget)
            {
                // 1. Check hover/click on the main dropdown box
                if (_mainBounds.Contains(internalMousePos))
                {
                    IsHovered = true;
                    if (isClick)
                    {
                        _isExpanded = !_isExpanded;
                        // If just expanded, recalculate bounds for interaction checks below
                        if (_isExpanded) CalculateExpandedListBounds(GameInstance.InternalWidth, GameInstance.InternalHeight);
                        isClick = false; 
                    }
                }

                // 2. If expanded, check hover/click on items
                if (_isExpanded)
                {
                    // Use pre-calculated _expandedListBounds and _itemBounds
                    if (_expandedListBounds.Contains(internalMousePos))
                    {
                         for (int i = 0; i < _itemBounds.Count; i++) 
                         {
                             Rectangle itemScreenRect = _itemBounds[i];
                             if (itemScreenRect.Contains(internalMousePos))
                             {
                                 _hoveredItemIndex = i;
                                 if (isClick)
                                 {
                                     // Set SelectedIndex, the setter will invoke the event
                                     SelectedIndex = i;
                                     _isExpanded = false;
                                     isClick = false;
                                 }
                                 break; 
                             }
                         }
                    }
                    else
                    { 
                         // Clicked outside list bounds but inside render target
                         if (isClick && !IsHovered) // Not hovering main box either
                         {
                             _isExpanded = false;
                             isClick = false;
                         }
                    }
                }
            }
            else
            {   // Clicked outside the render target area entirely
                 if (isClick && _isExpanded)
                 {
                     _isExpanded = false;
                     isClick = false;
                 }
            }

            _previousMouseState = mouseState;
        }

        /// <summary>
        /// Gets the list of items in the dropdown.
        /// </summary>
        public List<string> Items => _items;

        /// <summary>
        /// Explicitly expose the inherited Enabled property.
        /// This might help resolve compiler issues in some cases.
        /// </summary>
        public new bool Enabled
        {
            get => base.Enabled;
            set => base.Enabled = value;
        }

        /// <summary>
        /// Gets or sets the index of the currently selected item.
        /// </summary>
        public int SelectedIndex
        {
            get => _selectedIndex;
            set
            {
                int newIndex = Math.Clamp(value, -1, _items.Count - 1);
                if (_selectedIndex != newIndex)
                {
                    _selectedIndex = newIndex;
                    // Restore the event invocation when index changes
                    OnSelectionChanged?.Invoke(_selectedIndex, SelectedItem);
                    // Invalidate to redraw the current selection text
                    InvalidateRender();
                }
            }
        }

        /// <summary>
        /// Gets the currently selected item string. Returns null if no item is selected.
        /// </summary>
        public string? SelectedItem => (_selectedIndex >= 0 && _selectedIndex < _items.Count) ? _items[_selectedIndex] : null;

        // Store previous mouse state to detect clicks
        private MouseState _previousMouseState;

        /// <summary>
        /// Constructor
        /// </summary>
        public Dropdown(string id, int layerId, UIRectN rect) : base(id, layerId, rect)
        {
            // Default background for the main box (can be styled later)
            BackgroundColor = new Color(50, 50, 50, 200);
            // Use default font initially
            _currentFontName = GameInstance.Instance?.FontManager?.DefaultFontName ?? "default";
        }

        // --- Methods --- (To be implemented)
        public void SetFont(string? fontName, float fontSize)
        {
             _currentFontName = (!string.IsNullOrEmpty(fontName)) ? fontName : (GameInstance.Instance?.FontManager?.DefaultFontName ?? "default");
             _currentFontSize = fontSize;
             // Need to invalidate text rendering if font changes
        }
        
        public void AddItem(string item)
        {
            _items.Add(item);
            // If nothing was selected, select the first item
            if (_selectedIndex == -1 && _items.Count > 0)
            {
                 SelectedIndex = 0; 
            }
        }

        public void ClearItems()
        {
            _items.Clear();
            SelectedIndex = -1;
        }

        // TODO: Update method to handle input (opening/closing, item selection)
        // TODO: Draw method to draw the current selection, arrow, and expanded list
        // TODO: CheckMouseState override for interactions

        public override void Update(GameTime gameTime)
        {
            if (!Visible || !Enabled)
            {
                if (_isExpanded) _isExpanded = false; 
                return;
            }
            // Call CheckMouseState which is now part of UIElement's update flow
            base.Update(gameTime);
            // No need to handle outside click here if CheckMouseState does it
        }

        // --- Invalidation ---
        /// <summary>
        /// Invalidates the element, signaling it needs to be redrawn.
        /// (Currently a placeholder, add logic if specific redraw is needed)
        /// </summary>
        protected virtual void InvalidateRender()
        {
            // TODO: Implement specific invalidation logic if needed, 
            // e.g., setting a flag or clearing a cached texture.
            // For now, base UIElement might handle redraw implicitly, or Draw always redraws.
        }
    }
} 