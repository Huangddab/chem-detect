namespace SerialFileUp
{
    partial class MyComPortControl
    {
        /// <summary> 
        /// 必需的设计器变量。
        /// </summary>
        private System.ComponentModel.IContainer components = null;

        /// <summary> 
        /// 清理所有正在使用的资源。
        /// </summary>
        /// <param name="disposing">如果应释放托管资源，为 true；否则为 false。</param>
        protected override void Dispose(bool disposing)
        {
            try
            {
                    if (disposing && (components != null))
            {
                components.Dispose();
            }
            base.Dispose(disposing);
            }
            catch (System.Exception)
            {
                
                
            }
        }

        #region 组件设计器生成的代码

        /// <summary> 
        /// 设计器支持所需的方法 - 不要
        /// 使用代码编辑器修改此方法的内容。
        /// </summary>
        private void InitializeComponent()
        {
            this.components = new System.ComponentModel.Container();
            this.groupBox01 = new System.Windows.Forms.GroupBox();
            this.cmb_crc = new System.Windows.Forms.ComboBox();
            this.label3 = new System.Windows.Forms.Label();
            this.textBox3 = new System.Windows.Forms.TextBox();
            this.listBox1 = new System.Windows.Forms.ListBox();
            this.radioButton2 = new System.Windows.Forms.RadioButton();
            this.radioButton1 = new System.Windows.Forms.RadioButton();
            this.button3 = new System.Windows.Forms.Button();
            this.button2 = new System.Windows.Forms.Button();
            this.button1 = new System.Windows.Forms.Button();
            this.btn_startdown = new System.Windows.Forms.Button();
            this.cmb_BaudRate = new System.Windows.Forms.ComboBox();
            this.cmb_comName = new System.Windows.Forms.ComboBox();
            this.label2 = new System.Windows.Forms.Label();
            this.label23 = new System.Windows.Forms.Label();
            this.label24 = new System.Windows.Forms.Label();
            this.ComPort = new System.IO.Ports.SerialPort(this.components);
            this.textBox1 = new System.Windows.Forms.TextBox();
            this.groupBox1 = new System.Windows.Forms.GroupBox();
            this.textBox2 = new System.Windows.Forms.TextBox();
            this.button4 = new System.Windows.Forms.Button();
            this.progressBar1 = new System.Windows.Forms.ProgressBar();
            this.label1 = new System.Windows.Forms.Label();
            this.comboBox1 = new System.Windows.Forms.ComboBox();
            this.groupBox01.SuspendLayout();
            this.groupBox1.SuspendLayout();
            this.SuspendLayout();
            // 
            // groupBox01
            // 
            this.groupBox01.Controls.Add(this.cmb_crc);
            this.groupBox01.Controls.Add(this.label3);
            this.groupBox01.Controls.Add(this.textBox3);
            this.groupBox01.Controls.Add(this.listBox1);
            this.groupBox01.Controls.Add(this.radioButton2);
            this.groupBox01.Controls.Add(this.radioButton1);
            this.groupBox01.Controls.Add(this.button3);
            this.groupBox01.Controls.Add(this.button2);
            this.groupBox01.Controls.Add(this.button1);
            this.groupBox01.Controls.Add(this.btn_startdown);
            this.groupBox01.Controls.Add(this.cmb_BaudRate);
            this.groupBox01.Controls.Add(this.cmb_comName);
            this.groupBox01.Controls.Add(this.label2);
            this.groupBox01.Controls.Add(this.label23);
            this.groupBox01.Controls.Add(this.label24);
            this.groupBox01.ForeColor = System.Drawing.Color.White;
            this.groupBox01.Location = new System.Drawing.Point(11, 14);
            this.groupBox01.Name = "groupBox01";
            this.groupBox01.Size = new System.Drawing.Size(502, 348);
            this.groupBox01.TabIndex = 3;
            this.groupBox01.TabStop = false;
            this.groupBox01.Text = "Setting Parameter ";
            // 
            // cmb_crc
            // 
            this.cmb_crc.DropDownStyle = System.Windows.Forms.ComboBoxStyle.DropDownList;
            this.cmb_crc.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
            this.cmb_crc.FormattingEnabled = true;
            this.cmb_crc.Items.AddRange(new object[] {
            "none",
            "crc16",
            "crc32"});
            this.cmb_crc.Location = new System.Drawing.Point(416, 189);
            this.cmb_crc.Name = "cmb_crc";
            this.cmb_crc.Size = new System.Drawing.Size(71, 20);
            this.cmb_crc.TabIndex = 14;
            // 
            // label3
            // 
            this.label3.AutoSize = true;
            this.label3.ForeColor = System.Drawing.Color.White;
            this.label3.Location = new System.Drawing.Point(346, 197);
            this.label3.Name = "label3";
            this.label3.Size = new System.Drawing.Size(71, 12);
            this.label3.TabIndex = 13;
            this.label3.Text = "Verifying：";
            // 
            // textBox3
            // 
            this.textBox3.Location = new System.Drawing.Point(416, 158);
            this.textBox3.Name = "textBox3";
            this.textBox3.Size = new System.Drawing.Size(73, 21);
            this.textBox3.TabIndex = 12;
            this.textBox3.Text = "4000";
            // 
            // listBox1
            // 
            this.listBox1.BackColor = System.Drawing.Color.SteelBlue;
            this.listBox1.BorderStyle = System.Windows.Forms.BorderStyle.None;
            this.listBox1.Font = new System.Drawing.Font("宋体", 10.5F, System.Drawing.FontStyle.Regular, System.Drawing.GraphicsUnit.Point, ((byte)(134)));
            this.listBox1.ForeColor = System.Drawing.SystemColors.Info;
            this.listBox1.FormattingEnabled = true;
            this.listBox1.ItemHeight = 14;
            this.listBox1.Location = new System.Drawing.Point(9, 25);
            this.listBox1.Name = "listBox1";
            this.listBox1.Size = new System.Drawing.Size(312, 308);
            this.listBox1.TabIndex = 11;
            // 
            // radioButton2
            // 
            this.radioButton2.AutoSize = true;
            this.radioButton2.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
            this.radioButton2.Location = new System.Drawing.Point(431, 60);
            this.radioButton2.Name = "radioButton2";
            this.radioButton2.Size = new System.Drawing.Size(64, 16);
            this.radioButton2.TabIndex = 10;
            this.radioButton2.Tag = "S";
            this.radioButton2.Text = "Save SD";
            this.radioButton2.UseVisualStyleBackColor = true;
            // 
            // radioButton1
            // 
            this.radioButton1.AutoSize = true;
            this.radioButton1.Checked = true;
            this.radioButton1.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
            this.radioButton1.Location = new System.Drawing.Point(347, 60);
            this.radioButton1.Name = "radioButton1";
            this.radioButton1.Size = new System.Drawing.Size(70, 16);
            this.radioButton1.TabIndex = 10;
            this.radioButton1.TabStop = true;
            this.radioButton1.Tag = "R";
            this.radioButton1.Text = "Save RAM";
            this.radioButton1.UseVisualStyleBackColor = true;
            // 
            // button3
            // 
            this.button3.BackColor = System.Drawing.Color.LightSkyBlue;
            this.button3.FlatAppearance.BorderColor = System.Drawing.SystemColors.GradientActiveCaption;
            this.button3.FlatAppearance.BorderSize = 0;
            this.button3.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
            this.button3.Font = new System.Drawing.Font("宋体", 14.25F, System.Drawing.FontStyle.Regular, System.Drawing.GraphicsUnit.Point, ((byte)(134)));
            this.button3.Location = new System.Drawing.Point(343, 262);
            this.button3.Name = "button3";
            this.button3.Size = new System.Drawing.Size(144, 30);
            this.button3.TabIndex = 9;
            this.button3.Text = "EmptyFile";
            this.button3.UseVisualStyleBackColor = false;
            this.button3.Click += new System.EventHandler(this.button3_Click);
            // 
            // button2
            // 
            this.button2.BackColor = System.Drawing.Color.LightSkyBlue;
            this.button2.FlatAppearance.BorderColor = System.Drawing.SystemColors.GradientActiveCaption;
            this.button2.FlatAppearance.BorderSize = 0;
            this.button2.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
            this.button2.Font = new System.Drawing.Font("宋体", 14.25F, System.Drawing.FontStyle.Regular, System.Drawing.GraphicsUnit.Point, ((byte)(134)));
            this.button2.Location = new System.Drawing.Point(343, 298);
            this.button2.Name = "button2";
            this.button2.Size = new System.Drawing.Size(144, 32);
            this.button2.TabIndex = 9;
            this.button2.Text = "DelFile";
            this.button2.UseVisualStyleBackColor = false;
            this.button2.Click += new System.EventHandler(this.button2_Click);
            // 
            // button1
            // 
            this.button1.BackColor = System.Drawing.Color.LightSkyBlue;
            this.button1.FlatAppearance.BorderColor = System.Drawing.SystemColors.GradientActiveCaption;
            this.button1.FlatAppearance.BorderSize = 0;
            this.button1.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
            this.button1.Font = new System.Drawing.Font("宋体", 14.25F, System.Drawing.FontStyle.Regular, System.Drawing.GraphicsUnit.Point, ((byte)(134)));
            this.button1.Location = new System.Drawing.Point(343, 25);
            this.button1.Name = "button1";
            this.button1.Size = new System.Drawing.Size(148, 27);
            this.button1.TabIndex = 9;
            this.button1.Text = "AddFile";
            this.button1.UseVisualStyleBackColor = false;
            this.button1.Click += new System.EventHandler(this.button1_Click);
            // 
            // btn_startdown
            // 
            this.btn_startdown.BackColor = System.Drawing.Color.LightSkyBlue;
            this.btn_startdown.Cursor = System.Windows.Forms.Cursors.Hand;
            this.btn_startdown.FlatAppearance.BorderColor = System.Drawing.SystemColors.GradientActiveCaption;
            this.btn_startdown.FlatAppearance.BorderSize = 0;
            this.btn_startdown.FlatAppearance.MouseDownBackColor = System.Drawing.SystemColors.Highlight;
            this.btn_startdown.FlatAppearance.MouseOverBackColor = System.Drawing.Color.LightSkyBlue;
            this.btn_startdown.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
            this.btn_startdown.Font = new System.Drawing.Font("宋体", 14.25F, System.Drawing.FontStyle.Regular, System.Drawing.GraphicsUnit.Point, ((byte)(134)));
            this.btn_startdown.ForeColor = System.Drawing.Color.Black;
            this.btn_startdown.Location = new System.Drawing.Point(343, 223);
            this.btn_startdown.Name = "btn_startdown";
            this.btn_startdown.Size = new System.Drawing.Size(144, 33);
            this.btn_startdown.TabIndex = 6;
            this.btn_startdown.Text = "Start";
            this.btn_startdown.UseVisualStyleBackColor = false;
            this.btn_startdown.Click += new System.EventHandler(this.btn_startdown_Click);
            // 
            // cmb_BaudRate
            // 
            this.cmb_BaudRate.DropDownStyle = System.Windows.Forms.ComboBoxStyle.DropDownList;
            this.cmb_BaudRate.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
            this.cmb_BaudRate.FormattingEnabled = true;
            this.cmb_BaudRate.Items.AddRange(new object[] {
            "2400",
            "4800",
            "9600",
            "19200",
            "38400",
            "57600",
            "115200",
            "230400",
            "256000",
            "512000",
            "921600"});
            this.cmb_BaudRate.Location = new System.Drawing.Point(416, 127);
            this.cmb_BaudRate.Name = "cmb_BaudRate";
            this.cmb_BaudRate.Size = new System.Drawing.Size(73, 20);
            this.cmb_BaudRate.TabIndex = 1;
            // 
            // cmb_comName
            // 
            this.cmb_comName.DropDownStyle = System.Windows.Forms.ComboBoxStyle.DropDownList;
            this.cmb_comName.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
            this.cmb_comName.FormattingEnabled = true;
            this.cmb_comName.Location = new System.Drawing.Point(414, 89);
            this.cmb_comName.Name = "cmb_comName";
            this.cmb_comName.Size = new System.Drawing.Size(75, 20);
            this.cmb_comName.TabIndex = 1;
            // 
            // label2
            // 
            this.label2.AutoSize = true;
            this.label2.ForeColor = System.Drawing.Color.White;
            this.label2.Location = new System.Drawing.Point(346, 166);
            this.label2.Name = "label2";
            this.label2.Size = new System.Drawing.Size(77, 12);
            this.label2.TabIndex = 0;
            this.label2.Text = "DataPacket：";
            // 
            // label23
            // 
            this.label23.AutoSize = true;
            this.label23.ForeColor = System.Drawing.Color.White;
            this.label23.Location = new System.Drawing.Point(345, 133);
            this.label23.Name = "label23";
            this.label23.Size = new System.Drawing.Size(65, 12);
            this.label23.TabIndex = 0;
            this.label23.Text = "BaudRate：";
            // 
            // label24
            // 
            this.label24.AutoSize = true;
            this.label24.ForeColor = System.Drawing.Color.White;
            this.label24.Location = new System.Drawing.Point(345, 97);
            this.label24.Name = "label24";
            this.label24.Size = new System.Drawing.Size(65, 12);
            this.label24.TabIndex = 0;
            this.label24.Text = "ComPorts：";
            // 
            // textBox1
            // 
            this.textBox1.BackColor = System.Drawing.Color.SteelBlue;
            this.textBox1.BorderStyle = System.Windows.Forms.BorderStyle.None;
            this.textBox1.ForeColor = System.Drawing.Color.White;
            this.textBox1.Location = new System.Drawing.Point(11, 458);
            this.textBox1.Multiline = true;
            this.textBox1.Name = "textBox1";
            this.textBox1.ReadOnly = true;
            this.textBox1.ScrollBars = System.Windows.Forms.ScrollBars.Vertical;
            this.textBox1.Size = new System.Drawing.Size(502, 123);
            this.textBox1.TabIndex = 4;
            // 
            // groupBox1
            // 
            this.groupBox1.Controls.Add(this.comboBox1);
            this.groupBox1.Controls.Add(this.label1);
            this.groupBox1.Controls.Add(this.textBox2);
            this.groupBox1.Controls.Add(this.button4);
            this.groupBox1.ForeColor = System.Drawing.SystemColors.ButtonHighlight;
            this.groupBox1.Location = new System.Drawing.Point(11, 368);
            this.groupBox1.Name = "groupBox1";
            this.groupBox1.Size = new System.Drawing.Size(502, 83);
            this.groupBox1.TabIndex = 7;
            this.groupBox1.TabStop = false;
            this.groupBox1.Text = "Send Cmd";
            // 
            // textBox2
            // 
            this.textBox2.Font = new System.Drawing.Font("宋体", 12F, System.Drawing.FontStyle.Regular, System.Drawing.GraphicsUnit.Point, ((byte)(134)));
            this.textBox2.Location = new System.Drawing.Point(9, 46);
            this.textBox2.Multiline = true;
            this.textBox2.Name = "textBox2";
            this.textBox2.Size = new System.Drawing.Size(401, 28);
            this.textBox2.TabIndex = 11;
            // 
            // button4
            // 
            this.button4.BackColor = System.Drawing.Color.LightSkyBlue;
            this.button4.FlatAppearance.BorderColor = System.Drawing.SystemColors.GradientActiveCaption;
            this.button4.FlatAppearance.BorderSize = 0;
            this.button4.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
            this.button4.Font = new System.Drawing.Font("宋体", 14.25F, System.Drawing.FontStyle.Regular, System.Drawing.GraphicsUnit.Point, ((byte)(134)));
            this.button4.Location = new System.Drawing.Point(413, 46);
            this.button4.Name = "button4";
            this.button4.Size = new System.Drawing.Size(82, 28);
            this.button4.TabIndex = 10;
            this.button4.Text = "Send Cmd";
            this.button4.UseVisualStyleBackColor = false;
            this.button4.Click += new System.EventHandler(this.button4_Click);
            // 
            // progressBar1
            // 
            this.progressBar1.Location = new System.Drawing.Point(11, 587);
            this.progressBar1.Name = "progressBar1";
            this.progressBar1.Size = new System.Drawing.Size(502, 14);
            this.progressBar1.Step = 1;
            this.progressBar1.Style = System.Windows.Forms.ProgressBarStyle.Continuous;
            this.progressBar1.TabIndex = 9;
            // 
            // label1
            // 
            this.label1.AutoSize = true;
            this.label1.ForeColor = System.Drawing.Color.White;
            this.label1.Location = new System.Drawing.Point(11, 25);
            this.label1.Name = "label1";
            this.label1.Size = new System.Drawing.Size(53, 12);
            this.label1.TabIndex = 15;
            this.label1.Text = "Encode：";
            // 
            // comboBox1
            // 
            this.comboBox1.DropDownStyle = System.Windows.Forms.ComboBoxStyle.DropDownList;
            this.comboBox1.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
            this.comboBox1.FormattingEnabled = true;
            this.comboBox1.Items.AddRange(new object[] {
            "2400",
            "4800",
            "9600",
            "19200",
            "38400",
            "57600",
            "115200",
            "230400",
            "256000",
            "512000",
            "921600"});
            this.comboBox1.Location = new System.Drawing.Point(70, 20);
            this.comboBox1.Name = "comboBox1";
            this.comboBox1.Size = new System.Drawing.Size(167, 20);
            this.comboBox1.TabIndex = 16;
            // 
            // MyComPortControl
            // 
            this.AutoScaleDimensions = new System.Drawing.SizeF(6F, 12F);
            this.AutoScaleMode = System.Windows.Forms.AutoScaleMode.Font;
            this.BackColor = System.Drawing.Color.FromArgb(((int)(((byte)(128)))), ((int)(((byte)(128)))), ((int)(((byte)(255)))));
            this.Controls.Add(this.progressBar1);
            this.Controls.Add(this.groupBox1);
            this.Controls.Add(this.textBox1);
            this.Controls.Add(this.groupBox01);
            this.Name = "MyComPortControl";
            this.Size = new System.Drawing.Size(526, 631);
            this.Load += new System.EventHandler(this.MyComPortControl_Load);
            this.groupBox01.ResumeLayout(false);
            this.groupBox01.PerformLayout();
            this.groupBox1.ResumeLayout(false);
            this.groupBox1.PerformLayout();
            this.ResumeLayout(false);
            this.PerformLayout();

        }

        #endregion

        private System.Windows.Forms.ComboBox cmb_BaudRate;
        private System.Windows.Forms.Label label23;
        private System.Windows.Forms.Label label24;
        public System.Windows.Forms.ComboBox cmb_comName;
        public System.Windows.Forms.GroupBox groupBox01;
        private System.IO.Ports.SerialPort ComPort;
        private System.Windows.Forms.TextBox textBox1;
        private System.Windows.Forms.Button btn_startdown;
        private System.Windows.Forms.Button button1;
        private System.Windows.Forms.RadioButton radioButton2;
        private System.Windows.Forms.RadioButton radioButton1;
        private System.Windows.Forms.ListBox listBox1;
        private System.Windows.Forms.Button button2;
        private System.Windows.Forms.Button button3;
        private System.Windows.Forms.GroupBox groupBox1;
        private System.Windows.Forms.Button button4;
        private System.Windows.Forms.TextBox textBox2;
        private System.Windows.Forms.TextBox textBox3;
        private System.Windows.Forms.Label label2;
        public System.Windows.Forms.ComboBox cmb_crc;
        private System.Windows.Forms.Label label3;
        private System.Windows.Forms.ProgressBar progressBar1;
        private System.Windows.Forms.Label label1;
        private System.Windows.Forms.ComboBox comboBox1;
    }
}
