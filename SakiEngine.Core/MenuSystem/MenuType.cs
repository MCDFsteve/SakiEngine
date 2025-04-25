namespace SakiEngine.Core.MenuSystem
{
    /// <summary>
    /// 菜单类型
    /// </summary>
    public enum MenuType
    {
        /// <summary>
        /// 独占菜单 - 会暂停下层菜单更新与绘制
        /// </summary>
        Exclusive,
        
        /// <summary>
        /// 覆盖菜单 - 叠加在其他菜单上，不会阻止下层菜单更新
        /// </summary>
        Overlay
    }
} 