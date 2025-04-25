using Microsoft.Xna.Framework;

namespace SakiEngine.Core.Utils
{
    /// <summary>
    /// 归一化坐标矩形，所有属性都是0-1的比例值
    /// </summary>
    public struct UIRectN
    {
        /// <summary>
        /// X轴归一化坐标（0-1）
        /// </summary>
        public float X { get; set; }
        
        /// <summary>
        /// Y轴归一化坐标（0-1）
        /// </summary>
        public float Y { get; set; }
        
        /// <summary>
        /// 宽度归一化值（0-1）
        /// </summary>
        public float Width { get; set; }
        
        /// <summary>
        /// 高度归一化值（0-1）
        /// </summary>
        public float Height { get; set; }

        /// <summary>
        /// 构造函数
        /// </summary>
        public UIRectN(float x, float y, float width, float height)
        {
            X = x;
            Y = y;
            Width = width;
            Height = height;
        }

        /// <summary>
        /// 获取在指定分辨率下的实际矩形
        /// </summary>
        public Rectangle ToRectangle(int screenWidth, int screenHeight)
        {
            return new Rectangle(
                (int)(X * screenWidth),
                (int)(Y * screenHeight),
                (int)(Width * screenWidth),
                (int)(Height * screenHeight)
            );
        }

        /// <summary>
        /// 创建一个全屏矩形
        /// </summary>
        public static UIRectN FullScreen => new UIRectN(0, 0, 1, 1);

        /// <summary>
        /// 创建一个居中的矩形
        /// </summary>
        public static UIRectN Centered(float width, float height)
        {
            return new UIRectN(
                (1 - width) / 2,
                (1 - height) / 2,
                width,
                height
            );
        }
    }
} 