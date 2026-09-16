using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Data;
using System.Linq;
using System.Text;
using System.Windows.Forms;
using System.IO.Ports;
using System.Threading;
using System.IO;
using SerialFileUp.Properties;

namespace SerialFileUp
{
    public partial class MyComPortControl : UserControl
    {      
        private List<string> comlist = new List<string>();
        private List<string> filePaths = new List<string>();
        public MyComPortControl()
        {
            InitializeComponent();
        }
        private void MyComPortControl_Load(object sender, EventArgs e)
        {
            comboBox1.Items.Clear();
            comboBox1.Items.Add("ascii");
            comboBox1.Items.Add("gb2312");
            comboBox1.Items.Add("big5");
            comboBox1.Items.Add("utf-8");
            comboBox1.Items.Add("shift-jis");
            comboBox1.Items.Add("iso-8859-1");
            comboBox1.Items.Add("ks_c_5601-1987");
            comboBox1.Items.Add("windows-1255");
            comboBox1.Items.Add("koi8-r");
            comboBox1.SelectedIndex = 3;
            comlist = new List<string>(SerialPort.GetPortNames());
            for (int i = 0; i < comlist.Count(); i++)
            {               
                cmb_comName.Items.Add(comlist[i]);
            }
            if (comlist.Count() > 1) cmb_comName.SelectedIndex = 0;
            cmb_crc.SelectedIndex = 1;
        }
        private bool comportinit(string comname, int baud)
        {
            try
            {
                if (ComPort.IsOpen == true) ComPort.Close();
                ComPort.PortName = comname;
                ComPort.BaudRate = baud;
                ComPort.Parity = Parity.None;
                ComPort.DataBits = 8;
                ComPort.StopBits = StopBits.One;
                ComPort.Open();
                return true;
            }
            catch (Exception ex)
            {
                textBox1.AppendText(ex.Message + "\r\n");
            }
            return false;
        }
        private void com_sendstring(string str, Encoding en)
        {
            try
            {
                if (ComPort.IsOpen != true) return;
                byte[] endbytes = new byte[3] { 255, 255, 255 };
                byte[] bt1 = en.GetBytes(str);
                ComPort.Write(bt1, 0, bt1.Length);
                ComPort.Write(endbytes, 0, endbytes.Length);
            }
            catch (Exception ex)
            {
                MessageBoxForm.MsgBox("Error", ex.Message, "");
            }
        }
        public void ControlStatus(bool usable) 
        {
            cmb_comName.Enabled = usable;
            cmb_BaudRate.Enabled = usable;
            cmb_crc.Enabled = usable;
            button1.Enabled = usable;
            button2.Enabled = usable;
            button3.Enabled = usable;
            button4.Enabled = usable;
            radioButton1.Enabled = usable;
            radioButton2.Enabled = usable;
            textBox3.Enabled = usable;
          
        }
        //open comm  
        private void btn_startdown_Click(object sender, EventArgs e)
        {
            if (btn_startdown.Text == "Stop")// Already begin
            {
                if (DownFile.DownState != 0) DownFile.DownState = 0;
                ControlStatus(true);
                return;
            }    
            int crc = 0;
            int maxdatasize=4096;
            if (cmb_crc.Text == "crc16")
            {
                crc = 1;
                maxdatasize = 4094;
            }
            else if (cmb_crc.Text == "crc32")
            {
                crc = 10;
                maxdatasize = 4092;
            }
            int databag = 0;
            textBox1.Text = "";        
           // if (comlist.Count() <= 1)
           // {
             //   MessageBoxForm.MsgBox("Error", "Serial Port No Available", "");
            //    return;
        //    }
            if (listBox1.Items.Count < 1)
            {
                MessageBoxForm.MsgBox("Error", "Please Select  Files", "");
                return;
            }
            if (cmb_BaudRate.Text == "")
            {
                MessageBoxForm.MsgBox("Error", "Please Select  baudrate!", "");
                return;
            }
            string comName = cmb_comName.SelectedItem.ToString();
            int btl = Convert.ToInt32(cmb_BaudRate.SelectedItem.ToString());
            if (!comportinit(comName, btl))
            {
                textBox1.AppendText("No device found\r\n");
                return;
            }     
            if (string.IsNullOrEmpty(textBox3.Text))
            {
                MessageBoxForm.MsgBox("Error", "Data Packet cannot be empty", "");
                return;
            }
            try
            {
                databag = int.Parse(textBox3.Text);
            }
            catch (Exception)
            {
                MessageBoxForm.MsgBox("Error", "the Subcontract data set error", "");
                return;
            }
            if (databag < 1 || databag > maxdatasize)
            {
                MessageBoxForm.MsgBox("Error", "Data Packet size error", "");
                return;
            }
            btn_startdown.Text = "Stop";
            DownFile.DownState = 1;
            string DecPath = "";
            for (int i = 0; i < listBox1.Items.Count; i++)
            {
                ControlStatus(false);
                if (DownFile.DownState == 0) break;
                string filepath = listBox1.Items[i].ToString();                
                if (radioButton1.Checked == true)
                {
                    DecPath = "ram/"+Path.GetFileName(filepath);
                }
                else
                {
                    DecPath = "sd0/"+Path.GetFileName(filepath);
                }              
                if (File.Exists(filepath) == true)
                {
                    if (DownFile.DownLoad(ComPort,progressBar1, textBox1, filepath, DecPath, crc, databag) == false) break;
                }
            }
            btn_startdown.Text = "Start";
            ControlStatus(true);
            try
            {
                ComPort.Close();
            }
            catch (Exception)
            { }
        }
        //add file to listbox1
        private void button1_Click(object sender, EventArgs e)
        {
            OpenFileDialog openFileDialog = new OpenFileDialog();
            openFileDialog.Multiselect = true;
            openFileDialog.Filter = "Supported files(*.jpg;*.xi;)|*.jpg;*.xi;|All documents|*.*";

            if (openFileDialog.ShowDialog() == DialogResult.OK)
            {
                string[] imgs = openFileDialog.FileNames;

                filePaths.AddRange(imgs.ToList());
                listBox1.DataSource = null;
                listBox1.DataSource = filePaths;
            }
        }
        //del file from ram or sd
        private void button2_Click(object sender, EventArgs e)
        {
            if (listBox1.SelectedIndices.Count == 0)
            {
                MessageBoxForm.MsgBox("Error", "No Selected Any Thing", "");
                return;
            }
            string filepath = listBox1.SelectedItem.ToString();
            if (File.Exists(filepath) == false)
            {
                MessageBoxForm.MsgBox("Error", "Ther Selected File NO Exists", "");
                return;
            }
            string filename = Path.GetFileName(filepath);
            filePaths.Remove(filepath);
            listBox1.DataSource = null;
            listBox1.DataSource = filePaths;   
        }
        //send cmd  
        private void button4_Click(object sender, EventArgs e)
        {
            if (cmb_BaudRate.Text == "")
            {
                MessageBoxForm.MsgBox("Error", "Please Select  baudrate!", "");
                return;
            }
            if (string.IsNullOrEmpty(textBox2.Text))
            {
                MessageBoxForm.MsgBox("Error", "Command Cannot Empty ", "");
                return;
            }
            if (ComPort.IsOpen != true)
            {
                string comName = cmb_comName.SelectedItem.ToString();
                int btl = Convert.ToInt32(cmb_BaudRate.SelectedItem.ToString());
                if (!comportinit(comName, btl))
                {
                    textBox1.AppendText("No device found\r\n");
                    return;
                }
            }
            com_sendstring(textBox2.Text, Encoding.GetEncoding(comboBox1.Text));
            //  textBox1.AppendText(com_getstring() + "\r\n");
        }
        //empty  listbox1
        private void button3_Click(object sender, EventArgs e)
        {
            listBox1.DataSource = null;
            filePaths.Clear();
            MessageBoxForm.MsgBox("Success", "Operation Completion ", "");
        }
    }
}
