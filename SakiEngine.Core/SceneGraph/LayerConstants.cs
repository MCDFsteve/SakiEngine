namespace SakiEngine.Core.SceneGraph
{
    /// <summary>
    /// 游戏渲染层常量定义
    /// 越大的值层级越靠前（越上层）
    /// </summary>
    public static class LayerConstants
    {
        // 背景层 (0-999)
        public const int Background = 0;
        public const int BackgroundEffect = 500;
        
        // 角色层 (1000-1999)
        public const int CharacterBack = 1000;
        public const int CharacterMiddle = 1500;
        public const int CharacterFront = 1900;
        
        // 对话/UI层 (2000-2999)
        public const int DialogueBox = 2000;
        public const int DialogueText = 2100;
        public const int UIBackground = 2500;
        public const int UIElements = 2700;
        public const int UIText = 2800;
        
        // 菜单层 (3000-3999)
        public const int MenuBackground = 3000;
        public const int MenuElements = 3500;
        public const int MenuText = 3800;
        
        // 过渡效果层 (4000-4999)
        public const int TransitionEffect = 4000;
        
        // 鼠标光标层 (5000)
        public const int Cursor = 5000;
    }
} 