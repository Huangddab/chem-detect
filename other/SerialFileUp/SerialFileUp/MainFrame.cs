using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Data;
using System.Drawing;
using System.Linq;
using System.Text;
using System.Windows.Forms;
using System.Runtime.InteropServices;

namespace SerialFileUp
{
    public partial class MainFrame : Form
    {
        public MainFrame()
        {
            InitializeComponent();
        }
        [DllImport("user32.dll")]
        public static extern bool ReleaseCapture();
        [DllImport("user32.dll")]
        public static extern bool SendMessage(IntPtr hwnd, int wMsg, int wParam, int lParam);
        public const int WM_SYSCOMMAND = 0x0112;    
        public const int SC_MOVE = 0xF010;          
        public const int HTCAPTION = 0x0002;
        private void EMSecure_MouseDown(object sender, MouseEventArgs e)
        {
            ReleaseCapture();
            SendMessage(this.Handle, WM_SYSCOMMAND, SC_MOVE + HTCAPTION, 0);
        }
        private void btn_min_Click(object sender, EventArgs e)
        {
            if (this.WindowState == FormWindowState.Normal)
            {
                this.WindowState =FormWindowState.Minimized;
            }
        }
        private void myComPortControl1_Load(object sender, EventArgs e)
        {

        }
        //close
        private void btn_close_Click(object sender, EventArgs e)
        {
            System.Environment.Exit(0);
        }

        private void myComPortControl1_Load_1(object sender, EventArgs e)
        {

        }

        private void myComPortControl1_Load_2(object sender, EventArgs e)
        {

        }

        private void MainFrame_Load(object sender, EventArgs e)
        {

        }

       
    }
}
