using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Windows.Forms;
using System.Drawing;
using SerialFileUp.Properties;

namespace SerialFileUp
{
   public static class MessageBoxForm
    {
       public static void MsgBox(string Caption, string Hint, string Default)
       {
           Form uForm = new Form();
           uForm.MinimizeBox = false;
           uForm.MaximizeBox = false;
           uForm.ControlBox = false;
           uForm.BackColor = System.Drawing.Color.FromArgb(((int)(((byte)(128)))), ((int)(((byte)(128)))), ((int)(((byte)(245)))));
           uForm.StartPosition = FormStartPosition.CenterScreen;
           uForm.ForeColor = System.Drawing.SystemColors.ButtonHighlight;
           uForm.FormBorderStyle = System.Windows.Forms.FormBorderStyle.None;
           uForm.Location = new Point(50, 100);
           uForm.Width = 300;
           uForm.Height = 150;

           // msg content
           Label lbl = new Label();
           lbl.Text = Hint;
           lbl.Left = 50;
           lbl.Top = 50;
           lbl.Parent = uForm;
           lbl.Size = new Size(300, 21);
           lbl.ForeColor = System.Drawing.Color.White;

           // tips tile
           Label lbl0 = new Label();
           lbl0.Text = Caption;
           lbl0.Left = 3;
           lbl0.Top = 4;
           lbl0.Parent = uForm;
           lbl0.Size = new Size(120, 21);
           lbl0.Font = new System.Drawing.Font("宋体", 14.25F, System.Drawing.FontStyle.Regular, System.Drawing.GraphicsUnit.Point, ((byte)(134)));
           lbl0.ForeColor = System.Drawing.Color.White;

           //close botton
           Button btnclose = new Button();
           btnclose.Left = 265;
           btnclose.Top = 3;
           btnclose.FlatAppearance.BorderSize = 0;
           btnclose.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
           btnclose.Image = Resources.close;
           btnclose.Size = new System.Drawing.Size(32, 23);
           btnclose.UseVisualStyleBackColor = true;
           btnclose.Parent = uForm;
           uForm.AcceptButton = btnclose; //close
           btnclose.DialogResult = DialogResult.OK;

           Button btnok = new Button();
           btnok.Left = 50;
           btnok.Top = 110;
           btnok.BackColor = System.Drawing.Color.LightSkyBlue;
           btnok.FlatAppearance.BorderColor = System.Drawing.SystemColors.GradientActiveCaption;
           btnok.FlatAppearance.BorderSize = 0;
           btnok.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
           btnok.Font = new System.Drawing.Font("宋体", 13.25F, System.Drawing.FontStyle.Regular, System.Drawing.GraphicsUnit.Point, ((byte)(134)));
           btnok.Parent = uForm;
           btnok.Text = "OK";
           uForm.AcceptButton = btnok; //回车响应
           btnok.DialogResult = DialogResult.OK;

           Button btncancal = new Button();
           btncancal.Left = 180;
           btncancal.Top = 110;
           btncancal.BackColor = System.Drawing.Color.LightSkyBlue;
           btncancal.FlatAppearance.BorderColor = System.Drawing.SystemColors.GradientActiveCaption;
           btncancal.FlatAppearance.BorderSize = 0;
           btncancal.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
           btncancal.Font = new System.Drawing.Font("宋体", 13.25F, System.Drawing.FontStyle.Regular, System.Drawing.GraphicsUnit.Point, ((byte)(134)));
           btncancal.Parent = uForm;
           btncancal.Text = "Cancel";
           btncancal.DialogResult = DialogResult.Cancel;

           try
           {
               if (uForm.ShowDialog() == DialogResult.OK) return ;
               return;
           }
           catch (Exception ex)
           {
               MessageBox.Show(ex.Message);
               return;
           }
           finally
           {
               uForm.Dispose();
           }
       }
    }
}
